terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = merge(
      {
        Project         = var.project_name
        ConnectInstance = var.instance_alias
      },
      var.extra_tags,
    )
  }
}

data "aws_caller_identity" "current" {}

module "connect" {
  source         = "./modules/connect"
  instance_alias = var.instance_alias

  queue_name           = var.connect_queue_name
  queue_max_contacts   = var.connect_queue_max_contacts
  routing_profile_name = var.connect_routing_profile_name
  task_concurrency     = var.connect_task_concurrency
  hours_timezone       = var.connect_hours_timezone
  contact_flow_name    = var.connect_contact_flow_name

  agent_username              = var.agent_username
  agent_password              = var.agent_password
  agent_first_name            = var.agent_first_name
  agent_last_name             = var.agent_last_name
  agent_security_profile_name = var.agent_security_profile_name

  agents = var.agents

  supervisor_username              = var.supervisor_username
  supervisor_password              = var.supervisor_password
  supervisor_first_name            = var.supervisor_first_name
  supervisor_last_name             = var.supervisor_last_name
  supervisor_security_profile_name = var.supervisor_security_profile_name
}

module "email_storage" {
  source         = "./modules/email-storage"
  instance_alias = var.instance_alias
  account_id     = data.aws_caller_identity.current.account_id
  kms_key_arn    = var.kms_key_arn
}

module "salesforce_secret" {
  source               = "./modules/salesforce-secret"
  instance_alias       = var.instance_alias
  salesforce_login_url = var.salesforce_login_url
  kms_key_arn          = var.kms_key_arn
}

module "email_router" {
  source = "./modules/email-router"

  lambda_function_name = var.lambda_function_name
  lambda_runtime       = var.lambda_runtime
  lambda_timeout       = var.lambda_timeout
  lambda_memory_size   = var.lambda_memory_size
  instance_alias       = var.instance_alias
  kms_key_arn          = var.kms_key_arn

  inbound_bucket_name    = module.email_storage.bucket_name
  inbound_bucket_arn     = module.email_storage.bucket_arn
  inbound_object_prefix  = var.inbound_object_prefix
  ownership_table_name   = module.email_storage.ownership_table_name
  ownership_table_arn    = module.email_storage.ownership_table_arn
  routing_log_table_name = module.email_storage.routing_log_table_name
  routing_log_table_arn  = module.email_storage.routing_log_table_arn

  salesforce_secret_arn  = module.salesforce_secret.secret_arn
  salesforce_api_version = var.salesforce_api_version

  connect_instance_id  = module.connect.instance_id
  connect_instance_arn = module.connect.instance_arn
  contact_flow_arn     = module.connect.contact_flow_arn
  owner_flow_map       = module.connect.owner_flow_map
  # Native-email flow mode: auto-derived from the same agents map as owner_flow_map,
  # so adding/removing an agent needs no extra wiring. Fallback = the shared queue.
  owner_queue_map      = module.connect.owner_queue_map
  fallback_queue_arn   = module.connect.queue_arn

  # Native-email body fetch (Fix B): console-created EMAIL_MESSAGES bucket. ARN is
  # derived from the name (bucket isn't TF-managed). Prefix set once confirmed.
  connect_email_bucket_name = var.connect_email_bucket_name
  connect_email_bucket_arn  = var.connect_email_bucket_name != "" ? "arn:aws:s3:::${var.connect_email_bucket_name}" : ""
  connect_email_prefix      = var.connect_email_prefix

  shared_mailboxes         = var.shared_mailboxes
  case_id_regex            = var.case_id_regex
  auto_create_case         = var.auto_create_case
  log_email_to_salesforce  = var.log_email_to_salesforce
  link_customer_to_contact = var.link_customer_to_contact
}

# Associate the router Lambda with the Connect instance so contact flows may
# invoke it. Required by the inbound EMAIL flow (flow mode) and harmless to the
# Task path. Codified instead of the console "Flows -> AWS Lambda -> Add" click.
resource "aws_connect_lambda_function_association" "email_router" {
  instance_id  = module.connect.instance_id
  function_arn = module.email_router.lambda_arn
}

# No SES module — SES (domain identity, DKIM, receipt rule set/rule, activation,
# and the SES->Lambda invoke permission) is set up manually in the AWS Console.
# See docs/05-setup-ses-evolvity.md. Terraform only builds what SES points at:
# the S3 inbound bucket (+ policy) and the router Lambda.
