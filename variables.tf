variable "tags" {
  description = "Tags for the VPC resources"
  type        = map(string)
  default     = {}
}

variable "account_mapping" {
  type = object({
    name               = string
    aws_account        = string
    region             = string
    create_vpcs        = bool
    vpc_cidrs = object({
      region          = string
      name            = string
      cidr            = string
      secondary_cidrs = list(string)
      subnet = map(object({
        cidr             = string
        az               = map(string)
        reservation_list = optional(map(list(string)))
        reservation      = optional(map(string))
      }))
    })
    nacls = list(object({
      name = string
      rules = object({
        egress = list(object({
          id       = string
          cidr     = string
          protocol = string
          action   = optional(string)
        }))
        ingress = list(object({
          id        = string
          cidr      = string
          protocol  = string
          action    = optional(string)
          from_port = optional(string)
          to_port   = optional(string)
        }))
      })
      subnets = list(string)
    }))
    route_tables = list(object({
      name = string
      routes = optional(list(object({
        cidr = string
        resource = object({
          type  = string
          name  = string
          owner = optional(string)
          az    = optional(string)
        })
      })))
      subnets = optional(list(string))
    }))
    igw = optional(object({
      name = string
    }))
    nat_gws = optional(list(object({
      name   = string
      subnet = string
    })))
    gateway_endpoints = optional(list(object({
      aws_service  = string
      route_tables = list(string)
    })))
  })
}


# Default VPC param
variable "instance_tenancy" {
  type    = string
  default = "default"
}

variable "enable_dns_support" {
  type    = bool
  default = true
}

variable "enable_network_address_usage_metrics" {
  type    = bool
  default = false
}

variable "enable_dns_hostnames" {
  type    = bool
  default = true
}

variable "map_public_ip_on_launch" {
  type    = bool
  default = false
}

variable "enable_vpc_flow_logs" {
  type    = bool
  default = true
}

variable "vpc_flow_log_s3_arn" {
  type = string
  default = ""
}
