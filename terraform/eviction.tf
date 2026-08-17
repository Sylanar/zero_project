# Spot interruption → EventBridge → SSM Automation → Run Command
# → /opt/zero/handle_spot_eviction.sh
#
# Command documents cannot take a dynamic InstanceId from EventBridge
# (RunCommandParameters must be static). Automation accepts the instance
# id via input_transformer and then issues Run Command.
#
# Created only when environment=prod. Dev uses an on-box IMDS poller instead.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  automation_definition_arn = local.is_prod ? (
    "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.spot_eviction[0].name}:$DEFAULT"
  ) : null
  instance_arn_prefix  = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
  run_shell_script_arn = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"
}

data "aws_iam_policy_document" "ssm_automation_assume" {
  count = local.is_prod ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
    ]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ssm_automation" {
  count = local.is_prod ? 1 : 0

  statement {
    sid    = "SendEvictionShellScript"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      local.run_shell_script_arn,
    ]
  }

  statement {
    sid    = "SendCommandToClusterInstances"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      local.instance_arn_prefix,
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Cluster"
      values   = [var.cluster_name]
    }
  }

  statement {
    sid    = "CommandInvocationRead"
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommands",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
    ]
    # Command invocation APIs do not support resource-level permissions.
    resources = ["*"]
  }
}

resource "aws_iam_role" "ssm_automation" {
  count = local.is_prod ? 1 : 0

  name_prefix        = "${var.cluster_name}-ssm-auto-"
  assume_role_policy = data.aws_iam_policy_document.ssm_automation_assume[0].json

  tags = merge(var.default_tags, {
    Name    = "${var.cluster_name}-ssm-automation"
    Cluster = var.cluster_name
  })
}

resource "aws_iam_role_policy" "ssm_automation" {
  count = local.is_prod ? 1 : 0

  name_prefix = "ssm-auto-"
  role        = aws_iam_role.ssm_automation[0].id
  policy      = data.aws_iam_policy_document.ssm_automation[0].json
}

resource "aws_ssm_document" "spot_eviction" {
  count = local.is_prod ? 1 : 0

  # New name forces replace: AWS cannot UpdateDocument from Command → Automation.
  name            = "${var.cluster_name}-spot-eviction-auto"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Graceful Spot eviction: shutdown app, unmount data volume, terminate instance."
    assumeRole    = aws_iam_role.ssm_automation[0].arn
    parameters = {
      InstanceId = {
        type        = "String"
        description = "EC2 instance receiving the Spot interruption warning."
      }
    }
    mainSteps = [
      {
        name           = "RunEvictionScript"
        action         = "aws:runCommand"
        timeoutSeconds = var.eviction_lock_wait_seconds + 70
        inputs = {
          DocumentName = "AWS-RunShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "/opt/zero/handle_spot_eviction.sh",
            ]
            executionTimeout = [
              tostring(var.eviction_lock_wait_seconds + 50),
            ]
          }
        }
      },
    ]
  })

  tags = merge(var.default_tags, {
    Name    = "${var.cluster_name}-spot-eviction-auto"
    Cluster = var.cluster_name
  })

  depends_on = [aws_iam_role_policy.ssm_automation]
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  count = local.is_prod ? 1 : 0

  name        = "${var.cluster_name}-spot-interruption"
  description = "Catch EC2 Spot interruption warnings for ${var.cluster_name}."

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = merge(var.default_tags, {
    Name    = "${var.cluster_name}-spot-interruption"
    Cluster = var.cluster_name
  })
}

data "aws_iam_policy_document" "events_assume" {
  count = local.is_prod ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
    ]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "events_to_ssm" {
  count = local.is_prod ? 1 : 0

  # EventBridge authorizes StartAutomationExecution against the document ARN;
  # the automation-definition ARN alone is not enough and yields FailedInvocations
  # with no automation execution (and often nothing useful in CloudTrail).
  statement {
    sid    = "StartSpotEvictionAutomation"
    effect = "Allow"
    actions = [
      "ssm:StartAutomationExecution",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.spot_eviction[0].name}:*",
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:document/${aws_ssm_document.spot_eviction[0].name}",
      # EventBridge authorizes against automation-execution/* (see DLQ NO_PERMISSIONS).
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:automation-execution/*",
    ]
  }

  statement {
    sid    = "PassAutomationRole"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      aws_iam_role.ssm_automation[0].arn,
    ]
  }
}

resource "aws_iam_role" "events_to_ssm" {
  count = local.is_prod ? 1 : 0

  name_prefix        = "${var.cluster_name}-events-ssm-"
  assume_role_policy = data.aws_iam_policy_document.events_assume[0].json

  tags = merge(var.default_tags, {
    Name    = "${var.cluster_name}-events-ssm"
    Cluster = var.cluster_name
  })
}

resource "aws_iam_role_policy" "events_to_ssm" {
  count = local.is_prod ? 1 : 0

  name_prefix = "events-ssm-"
  role        = aws_iam_role.events_to_ssm[0].id
  policy      = data.aws_iam_policy_document.events_to_ssm[0].json
}

# Capture EventBridge target failures (FailedInvocations) with the error reason.
# Retry attempts = 0 so the next failed Spot warning lands in the DLQ immediately
# instead of after the default 24h retry window.
resource "aws_sqs_queue" "spot_eviction_dlq" {
  count = local.is_prod ? 1 : 0

  name                      = "${var.cluster_name}-spot-eviction-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = merge(var.default_tags, {
    Name    = "${var.cluster_name}-spot-eviction-dlq"
    Cluster = var.cluster_name
  })
}

data "aws_iam_policy_document" "spot_eviction_dlq" {
  count = local.is_prod ? 1 : 0

  statement {
    sid    = "AllowEventBridgeSend"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.spot_eviction_dlq[0].arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.spot_interruption[0].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "spot_eviction_dlq" {
  count = local.is_prod ? 1 : 0

  queue_url = aws_sqs_queue.spot_eviction_dlq[0].id
  policy    = data.aws_iam_policy_document.spot_eviction_dlq[0].json
}

resource "aws_cloudwatch_event_target" "spot_eviction_ssm" {
  count = local.is_prod ? 1 : 0

  rule      = aws_cloudwatch_event_rule.spot_interruption[0].name
  target_id = "spot-eviction-ssm"
  arn       = local.automation_definition_arn
  role_arn  = aws_iam_role.events_to_ssm[0].arn

  # Automation parameters must be JSON arrays when passed from EventBridge.
  input_transformer {
    input_paths = {
      instanceid = "$.detail.instance-id"
    }
    input_template = "{\"InstanceId\":[\"<instanceid>\"]}"
  }

  dead_letter_config {
    arn = aws_sqs_queue.spot_eviction_dlq[0].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 60
    maximum_retry_attempts       = 0
  }

  depends_on = [aws_sqs_queue_policy.spot_eviction_dlq]
}
