# Spot interruption → EventBridge → SSM Automation → Run Command
# → /opt/zero/handle_spot_eviction.sh
#
# Command documents cannot take a dynamic InstanceId from EventBridge
# (RunCommandParameters must be static). Automation accepts the instance
# id via input_transformer and then issues Run Command.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  automation_definition_arn = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.spot_eviction.name}:$DEFAULT"
  instance_arn_prefix       = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
  run_shell_script_arn      = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"
}

data "aws_iam_policy_document" "ssm_automation_assume" {
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
  name_prefix        = "${var.cluster_name}-ssm-auto-"
  assume_role_policy = data.aws_iam_policy_document.ssm_automation_assume.json

  tags = merge(var.default_tags, {
    Name    = "${var.cluster_name}-ssm-automation"
    Cluster = var.cluster_name
  })
}

resource "aws_iam_role_policy" "ssm_automation" {
  name_prefix = "ssm-auto-"
  role        = aws_iam_role.ssm_automation.id
  policy      = data.aws_iam_policy_document.ssm_automation.json
}

resource "aws_ssm_document" "spot_eviction" {
  # New name forces replace: AWS cannot UpdateDocument from Command → Automation.
  name            = "${var.cluster_name}-spot-eviction-auto"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Graceful Spot eviction: shutdown app, unmount data volume, terminate instance."
    assumeRole    = aws_iam_role.ssm_automation.arn
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
        timeoutSeconds = 120
        inputs = {
          DocumentName = "AWS-RunShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "/opt/zero/handle_spot_eviction.sh",
            ]
            executionTimeout = [
              "90",
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
  statement {
    sid    = "StartSpotEvictionAutomation"
    effect = "Allow"
    actions = [
      "ssm:StartAutomationExecution",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.spot_eviction.name}:*",
    ]
  }

  statement {
    sid    = "PassAutomationRole"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      aws_iam_role.ssm_automation.arn,
    ]
  }
}

resource "aws_iam_role" "events_to_ssm" {
  name_prefix        = "${var.cluster_name}-events-ssm-"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json

  tags = merge(var.default_tags, {
    Name    = "${var.cluster_name}-events-ssm"
    Cluster = var.cluster_name
  })
}

resource "aws_iam_role_policy" "events_to_ssm" {
  name_prefix = "events-ssm-"
  role        = aws_iam_role.events_to_ssm.id
  policy      = data.aws_iam_policy_document.events_to_ssm.json
}

resource "aws_cloudwatch_event_target" "spot_eviction_ssm" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "spot-eviction-ssm"
  arn       = local.automation_definition_arn
  role_arn  = aws_iam_role.events_to_ssm.arn

  # Automation parameters must be JSON arrays when passed from EventBridge.
  input_transformer {
    input_paths = {
      instanceid = "$.detail.instance-id"
    }
    input_template = "{\"InstanceId\":[\"<instanceid>\"]}"
  }
}
