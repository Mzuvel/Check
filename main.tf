# ============================================================
# AETHERIS OMNIVERSE — Terraform: Multi-Region Infrastructure
# Regions: us-east-1 (primary), eu-west-1, ap-southeast-1
# ============================================================

terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "aetheris-terraform-state"
    key            = "production/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "aetheris-terraform-lock"
    kms_key_id     = "alias/aetheris-terraform"
  }
}

# ── Providers ──────────────────────────────────────────────

provider "aws" {
  region = var.primary_region
  default_tags {
    tags = {
      Project     = "aetheris-omniverse"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "eu"
  region = "eu-west-1"
}

provider "aws" {
  alias  = "ap"
  region = "ap-southeast-1"
}

# ── Variables ──────────────────────────────────────────────

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  type = object({
    game_state  = list(string)
    general     = list(string)
    anticheat   = list(string)
  })
  default = {
    game_state  = ["c6i.4xlarge", "c6a.4xlarge"]  # Compute-optimized
    general     = ["m6i.2xlarge", "m6a.2xlarge"]  # General purpose
    anticheat   = ["g4dn.xlarge"]                  # GPU for AI inference
  }
}

# ── EKS Cluster (us-east-1) ────────────────────────────────

module "eks_us_east" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "aetheris-prod-us-east-1"
  cluster_version = var.cluster_version

  vpc_id     = module.vpc_us_east.vpc_id
  subnet_ids = module.vpc_us_east.private_subnets

  # Public endpoint access restricted to CI/CD IPs
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.ci_cd_cidr_blocks

  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = 4
        resources = {
          limits   = { cpu = "0.25", memory = "256Mi" }
          requests = { cpu = "0.1",  memory = "70Mi" }
        }
      })
    }
    kube-proxy    = { most_recent = true }
    vpc-cni       = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }

  # Managed node groups
  eks_managed_node_groups = {

    # Game state + multiplayer — high-CPU, compute-optimized
    game_state = {
      name           = "game-state"
      instance_types = var.node_instance_types.game_state
      ami_type       = "AL2_x86_64"
      capacity_type  = "ON_DEMAND"

      min_size     = 20
      max_size     = 200
      desired_size = 30

      labels = {
        "aetheris.gg/node-type" = "game-state"
      }
      taints = [{
        key    = "aetheris.gg/game-state"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }

    # General workloads (gateway, auth, economy, etc.)
    general = {
      name           = "general"
      instance_types = var.node_instance_types.general
      ami_type       = "AL2_x86_64"
      capacity_type  = "ON_DEMAND"

      min_size     = 10
      max_size     = 100
      desired_size = 15

      labels = {
        "aetheris.gg/node-type" = "general"
      }
    }

    # Anti-cheat AI inference (GPU nodes)
    anticheat = {
      name           = "anticheat-gpu"
      instance_types = var.node_instance_types.anticheat
      ami_type       = "AL2_x86_64_GPU"
      capacity_type  = "SPOT"   # Cost optimization — AI inference tolerates interruption

      min_size     = 2
      max_size     = 40
      desired_size = 4

      labels = {
        "aetheris.gg/node-type"       = "anticheat"
        "nvidia.com/gpu"              = "true"
      }
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }

    # Spot instances for non-critical burst (streaming, analytics)
    spot_burst = {
      name           = "spot-burst"
      instance_types = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge", "m5a.xlarge"]
      ami_type       = "AL2_x86_64"
      capacity_type  = "SPOT"

      min_size     = 0
      max_size     = 100
      desired_size = 0

      labels = {
        "aetheris.gg/node-type" = "spot-burst"
      }
      taints = [{
        key    = "aetheris.gg/spot"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  tags = {
    Component = "eks-cluster"
    Region    = var.primary_region
  }
}

# ── VPC (us-east-1) ────────────────────────────────────────

module "vpc_us_east" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "aetheris-prod-us-east-1"
  cidr = "10.0.0.0/16"

  azs              = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets  = ["10.0.1.0/24",  "10.0.2.0/24",  "10.0.3.0/24"]
  public_subnets   = ["10.0.101.0/24","10.0.102.0/24","10.0.103.0/24"]
  database_subnets = ["10.0.201.0/24","10.0.202.0/24","10.0.203.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = false  # One per AZ for HA
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs for security auditing
  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true

  tags = {
    "kubernetes.io/cluster/aetheris-prod-us-east-1" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ── RDS PostgreSQL (CitusDB / Aurora) ─────────────────────

resource "aws_rds_cluster" "aetheris_postgres" {
  cluster_identifier      = "aetheris-prod-postgres"
  engine                  = "aurora-postgresql"
  engine_version          = "16.2"
  database_name           = "aetheris"
  master_username         = "aetheris_admin"
  manage_master_user_password = true   # AWS Secrets Manager rotation

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.aetheris.name

  # Multi-AZ Aurora Global Database for cross-region reads
  global_cluster_identifier = aws_rds_global_cluster.aetheris.id

  storage_encrypted = true
  kms_key_id        = aws_kms_key.aetheris_data.arn

  backup_retention_period   = 30
  preferred_backup_window   = "03:00-04:00"
  copy_tags_to_snapshot     = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "aetheris-prod-final-${formatdate("YYYYMMDD", timestamp())}"

  # Performance Insights
  performance_insights_enabled          = true
  performance_insights_retention_period = 731  # 2 years

  enabled_cloudwatch_logs_exports = ["postgresql"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_rds_cluster_instance" "aetheris_postgres_instances" {
  count              = 3   # 1 writer + 2 readers per region
  identifier         = "aetheris-prod-postgres-${count.index}"
  cluster_identifier = aws_rds_cluster.aetheris_postgres.id
  instance_class     = "db.r6g.4xlarge"
  engine             = aws_rds_cluster.aetheris_postgres.engine
  engine_version     = aws_rds_cluster.aetheris_postgres.engine_version

  performance_insights_enabled = true
  monitoring_interval          = 10
  monitoring_role_arn          = aws_iam_role.rds_enhanced_monitoring.arn
}

resource "aws_rds_global_cluster" "aetheris" {
  global_cluster_identifier = "aetheris-prod-global"
  engine                    = "aurora-postgresql"
  engine_version            = "16.2"
}

# ── ElastiCache Redis Cluster ──────────────────────────────

resource "aws_elasticache_replication_group" "aetheris_redis" {
  replication_group_id       = "aetheris-prod-redis"
  description                = "Aetheris session cache + WS adapter"
  node_type                  = "cache.r7g.2xlarge"
  num_cache_clusters         = 6   # 3 shards × 2 replicas
  automatic_failover_enabled = true
  multi_az_enabled           = true
  engine_version             = "7.2"
  port                       = 6379
  parameter_group_name       = aws_elasticache_parameter_group.aetheris.name

  subnet_group_name  = aws_elasticache_subnet_group.aetheris.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  snapshot_retention_limit = 7
  snapshot_window          = "04:00-05:00"

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }
}

resource "aws_elasticache_parameter_group" "aetheris" {
  name   = "aetheris-redis-7-2"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
  parameter {
    name  = "hz"
    value = "20"   # Higher frequency server-cron for faster expiry
  }
  parameter {
    name  = "activerehashing"
    value = "yes"
  }
}

# ── KMS Keys ──────────────────────────────────────────────

resource "aws_kms_key" "aetheris_data" {
  description             = "Aetheris data encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Purpose = "data-encryption"
  }
}

resource "aws_kms_alias" "aetheris_data" {
  name          = "alias/aetheris-data"
  target_key_id = aws_kms_key.aetheris_data.key_id
}

# ── CloudFront (Asset CDN) ─────────────────────────────────

resource "aws_cloudfront_distribution" "aetheris_assets" {
  comment         = "Aetheris asset CDN"
  price_class     = "PriceClass_All"
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"  # HTTP/3 QUIC support

  aliases = ["assets.aetheris.gg"]

  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = "S3-aetheris-assets"
    origin_access_control_id = aws_cloudfront_origin_access_control.aetheris.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-aetheris-assets"
    viewer_protocol_policy = "redirect-to-https"

    cache_policy_id          = aws_cloudfront_cache_policy.aggressive.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.cors.id
    compress                 = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.cache_normalization.arn
    }
  }

  # Long-lived cache for immutable assets (hashed filenames)
  ordered_cache_behavior {
    path_pattern           = "/assets/v*/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-aetheris-assets"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.immutable.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.aetheris.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  web_acl_id = aws_wafv2_web_acl.aetheris_cdn.arn

  logging_config {
    include_cookies = false
    bucket          = aws_s3_bucket.cf_logs.bucket_domain_name
  }
}

resource "aws_cloudfront_cache_policy" "aggressive" {
  name        = "aetheris-aggressive"
  min_ttl     = 0
  default_ttl = 86400    # 1 day
  max_ttl     = 31536000 # 1 year

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config  { cookie_behavior = "none" }
    headers_config  { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

resource "aws_cloudfront_cache_policy" "immutable" {
  name        = "aetheris-immutable"
  min_ttl     = 31536000
  default_ttl = 31536000
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config       { cookie_behavior       = "none" }
    headers_config       { header_behavior       = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

# ── Outputs ────────────────────────────────────────────────

output "eks_cluster_endpoint" {
  value       = module.eks_us_east.cluster_endpoint
  sensitive   = true
  description = "EKS cluster API server endpoint"
}

output "rds_cluster_endpoint" {
  value       = aws_rds_cluster.aetheris_postgres.endpoint
  sensitive   = true
}

output "rds_reader_endpoint" {
  value       = aws_rds_cluster.aetheris_postgres.reader_endpoint
  sensitive   = true
}

output "redis_primary_endpoint" {
  value       = aws_elasticache_replication_group.aetheris_redis.primary_endpoint_address
  sensitive   = true
}

output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.aetheris_assets.domain_name
  description = "CDN domain for asset delivery"
}

variable "ci_cd_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]  # Override in prod with actual CI/CD IPs
}
