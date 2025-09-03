locals {
  
  subnets = flatten([
    for subnet_type, subnet in var.account_mapping.vpc_cidrs.subnet : [
      for az, cidr in subnet.az : {
        name             = "${var.account_mapping.vpc_cidrs.name}-${subnet_type}-${az}"
        cidr             = cidr
        az               = az
        reservation_list = lookup(subnet, "reservation_list", null) != null ? lookup(subnet.reservation_list, az, null) : null                                                                     # get reservation list if exists
        reservation      = lookup(subnet, "reservation", null) != null ? lookup(subnet.reservation, az, null) : null                                                                               # get reservation list if exists
        tags             = lower(subnet_type) != null && strcontains(lower(subnet_type), "corp") ? merge(local.tags, { Name = "${var.account_mapping.vpc_cidrs.name}-hybrid-${az}" }) : local.tags # add hybrid tag if subnet type contains "corp"
      }
    ]
  ])
  nacls = flatten([
    for nacl in var.account_mapping.nacls : [{
      name = nacl.name
      tags = lower(nacl.name) != null && strcontains(lower(nacl.name), "-corp") ? merge(local.tags, { Name = "${var.account_mapping.vpc_cidrs.name}-hybrid" }) : local.tags # add hybrid tag if nacl name contains "corp"
      rules = {
        egress = nacl.rules.egress
        ingress = [
          for rule in nacl.rules.ingress : {
            id = rule.id
            cidr = can(regex("^subnet\\.", rule.cidr)) ? var.account_mapping.vpc_cidrs.subnet[split(".", rule.cidr)[1]].cidr : (
              can(regex("^lookup\\.", rule.cidr)) ? var.account_mapping.global_cidr[split(".", rule.cidr)[1]] : rule.cidr
            )
            protocol  = rule.protocol
            action    = rule.action
            from_port = rule.from_port
            to_port   = rule.to_port
          }
        ]
      }
      subnets = nacl.subnets
    }]
  ])
  route_tables = flatten([
    for route_table in var.account_mapping.route_tables : [{
      name = route_table.name
      tags = lower(route_table.name) != null && strcontains(lower(route_table.name), "-corp") ? merge(local.tags, { Name = "${var.account_mapping.vpc_cidrs.name}-hybrid" }) : local.tags
      routes = route_table.routes != null ? [
        for route in route_table.routes : {
          cidr = try(route.cidr, null)
          resource = try({
            type = try(route.resource.type, null)
            name = try(can(regex("^lookup\\.project_name", route.resource.name)) ? replace(route.resource.name, "lookup.project_name", var.account_mapping.project_name) : route.resource.name, null)
            az = route.resource.type == "net_fw" ? route.resource.az : ""
          }, null)
        } if route != null
      ] : null
      subnets = route_table.subnets
    }]
  ])

  tags = merge({
          "hkjc:module" = "terraform-aws-vpc-vending"
          "hkjc:module-version" = "v1.0.0"
          }, var.tags)

  igw = var.account_mapping.igw != null ? {
    name = var.account_mapping.igw.name
    tags = local.tags
  } : null

  nat_gws = var.account_mapping.nat_gws != null ? flatten([for nat_gw in var.account_mapping.nat_gws : {
    name   = nat_gw.name
    subnet = nat_gw.subnet
    tags   = local.tags
  }]) : []

  gateway_endpoints = var.account_mapping.gateway_endpoints != null ? flatten([for gateway_endpoint in var.account_mapping.gateway_endpoints : {
    aws_service  = gateway_endpoint.aws_service
    route_tables = gateway_endpoint.route_tables
    tags         = local.tags
  }]) : []

  # reform the account_mapping
  account_mapping = {
    name                                       = var.account_mapping.name
    aws_account                                = var.account_mapping.aws_account
    region                                     = var.account_mapping.region
    create_vpcs                                = var.account_mapping.create_vpcs
    vpc_cidrs                                  = var.account_mapping.vpc_cidrs
    nacls                                      = local.nacls
    route_tables                               = local.route_tables
    igw                                        = local.igw
    nat_gws                                    = local.nat_gws
    gateway_endpoints                          = local.gateway_endpoints
    subnets                                    = local.subnets
  }
}
