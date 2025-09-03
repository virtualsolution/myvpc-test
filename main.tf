resource "aws_vpc" "vpc" {
  cidr_block                           = local.account_mapping.vpc_cidrs.cidr
  instance_tenancy                     = var.instance_tenancy
  enable_dns_support                   = var.enable_dns_support
  enable_network_address_usage_metrics = var.enable_network_address_usage_metrics
  enable_dns_hostnames                 = var.enable_dns_hostnames
  tags                                 = merge({ Name = "${local.account_mapping.name}" }, local.tags)
}

resource "aws_vpc_ipv4_cidr_block_association" "cidr_block_association" {
  for_each   = { for idx, cidr in local.account_mapping.vpc_cidrs.secondary_cidrs : "${local.account_mapping.aws_account}-${local.account_mapping.vpc_cidrs.name}-${local.account_mapping.region}-${replace(replace(cidr, ".", ""), "/", "")}" => cidr }
  vpc_id     = aws_vpc.vpc.id
  cidr_block = each.value
}

resource "aws_flow_log" "vpc_s3" {
  count                = var.enable_vpc_flow_logs ? 1 : 0
  log_destination_type = "s3"
  log_destination      = "${var.vpc_flow_log_s3_arn}"
  log_format           = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${vpc-id} $${tcp-flags}"
  tags                 = { Name = "vpc-flow-log-s3" }
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.vpc.id
}

resource "aws_subnet" "subnets" {
  for_each                = { for subnet in local.account_mapping.subnets : "${local.account_mapping.aws_account}-${subnet.name}-${local.account_mapping.region}" => subnet }
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = each.value.cidr
  availability_zone       = "${local.account_mapping.region}${each.value.az}"
  map_public_ip_on_launch = var.map_public_ip_on_launch
  tags                    = merge({ Name = each.value.name }, lookup(each.value, "tags", {}))
  depends_on              = [aws_vpc_ipv4_cidr_block_association.cidr_block_association]
}

resource "aws_ec2_subnet_cidr_reservation" "subnet_reservations" {
  for_each         = { for subnet in local.account_mapping.subnets : "${local.account_mapping.aws_account}-${subnet.name}-${local.account_mapping.region}_reservation" => subnet if lookup(subnet, "reservation", null) != null }
  cidr_block       = each.value.reservation
  reservation_type = "prefix"
  subnet_id        = aws_subnet.subnets["${local.account_mapping.aws_account}-${each.value.name}-${local.account_mapping.region}"].id
  depends_on       = [aws_subnet.subnets]
}

resource "aws_ec2_subnet_cidr_reservation" "subnet_reservation_lists" {
  for_each = { for res in flatten([
    for subnet in local.account_mapping.subnets :
    lookup(subnet, "reservation_list", null) != null ? [
      for cidr in subnet.reservation_list : {
        subnet_name = subnet.name
        cidr        = cidr
      }
    ] : []
  ]) : "${local.account_mapping.aws_account}-${res.subnet_name}-${local.account_mapping.region}-reservation-${res.cidr}" => res }
  cidr_block       = each.value.cidr
  reservation_type = "explicit"
  subnet_id        = aws_subnet.subnets["${local.account_mapping.aws_account}-${each.value.subnet_name}-${local.account_mapping.region}"].id
}

resource "aws_internet_gateway" "igw" {
  count  = local.account_mapping.igw != null ? 1 : 0
  vpc_id = aws_vpc.vpc.id
  tags   = merge({ Name = local.account_mapping.igw.name }, lookup(local.account_mapping.igw, "tags", {}))
}

resource "aws_eip" "nat_gw_eips" {
  for_each = { for nat_gw in local.account_mapping.nat_gws : "${local.account_mapping.aws_account}-nat-gw-${nat_gw.name}-${local.account_mapping.region}" => nat_gw if lookup(nat_gw, "connectivity_type", "public") == "public" }
  #vpc      = true
  domain = "vpc"
  tags   = merge({ Name = "nat-gw-${each.value.name}" }, lookup(each.value, "tags", {}))
}

resource "aws_nat_gateway" "nat_gws" {
  for_each          = { for nat_gw in local.account_mapping.nat_gws : "${local.account_mapping.aws_account}-${nat_gw.name}-${local.account_mapping.region}" => nat_gw }
  allocation_id     = lookup(aws_eip.nat_gw_eips, "${local.account_mapping.aws_account}-nat-gw-${each.value.name}-${local.account_mapping.region}", null) != null ? aws_eip.nat_gw_eips["${local.account_mapping.aws_account}-nat-gw-${each.value.name}-${local.account_mapping.region}"].id : null
  connectivity_type = lookup(each.value, "connectivity_type", "public")
  subnet_id         = aws_subnet.subnets["${local.account_mapping.aws_account}-${each.value.subnet}-${local.account_mapping.region}"].id
  tags              = merge({ Name = each.value.name }, lookup(each.value, "tags", {}))
}

resource "aws_network_acl" "nacls" {
  for_each = { for nacl in local.account_mapping.nacls : "${local.account_mapping.aws_account}-${nacl.name}-${local.account_mapping.region}" => nacl }
  vpc_id   = aws_vpc.vpc.id
  tags     = merge({ Name = each.value.name }, lookup(each.value, "tags", {}))
}

resource "aws_network_acl_association" "nacl_associations" {
  for_each = { for assoc in flatten([
    for nacl in local.account_mapping.nacls : [
      for subnet in nacl.subnets : {
        nacl_name   = nacl.name
        subnet_name = subnet
      }
    ]
  ]) : "${local.account_mapping.aws_account}-${assoc.nacl_name}-${local.account_mapping.region}-${assoc.subnet_name}" => assoc }
  network_acl_id = aws_network_acl.nacls["${local.account_mapping.aws_account}-${each.value.nacl_name}-${local.account_mapping.region}"].id
  subnet_id      = aws_subnet.subnets["${local.account_mapping.aws_account}-${each.value.subnet_name}-${local.account_mapping.region}"].id
}

resource "aws_network_acl_rule" "nacl_rules" {
  for_each = { for rule in flatten([
    for nacl in local.account_mapping.nacls : [
      for rule_type in ["egress", "ingress"] : [
        for rule in lookup(lookup(nacl, "rules", {}), rule_type, []) : {
          nacl_name = nacl.name
          rule_type = rule_type
          rule      = rule
        }
      ]
    ]
  ]) : "${local.account_mapping.aws_account}-${rule.nacl_name}-${local.account_mapping.region}-${rule.rule_type}-${rule.rule.id}" => rule }
  network_acl_id = aws_network_acl.nacls["${local.account_mapping.aws_account}-${each.value.nacl_name}-${local.account_mapping.region}"].id
  rule_number    = tonumber(each.value.rule.id)
  egress         = each.value.rule_type == "egress"
  protocol       = each.value.rule.protocol == "icmp" ? "1" : each.value.rule.protocol
  rule_action    = lookup(each.value.rule, "action", null) == null ? "allow" : each.value.rule.action
  cidr_block     = each.value.rule.cidr
  from_port      = each.value.rule.protocol != "all" && each.value.rule.protocol != "icmp" ? tonumber(each.value.rule.from_port) : null
  to_port        = each.value.rule.protocol != "all" && each.value.rule.protocol != "icmp" ? tonumber(each.value.rule.to_port) : null
  icmp_type      = each.value.rule.protocol == "icmp" ? -1 : null
  icmp_code      = each.value.rule.protocol == "icmp" ? -1 : null
}

resource "aws_route_table" "route_tables" {
  for_each = { for rt in local.account_mapping.route_tables : "${local.account_mapping.aws_account}-${rt.name}-${local.account_mapping.region}" => rt }
  vpc_id   = aws_vpc.vpc.id
  tags     = merge({ Name = each.value.name }, lookup(each.value, "tags", {}))
}

resource "aws_route_table_association" "subnet_associations" {
  for_each = { for assoc in flatten([
    for rt in local.account_mapping.route_tables : [
      for subnet in lookup(rt, "subnets", []) : {
        rt_name     = rt.name
        subnet_name = subnet
      }
    ]
  ]) : "${local.account_mapping.aws_account}-${assoc.rt_name}-${local.account_mapping.region}-${assoc.subnet_name}" => assoc }
  route_table_id = aws_route_table.route_tables["${local.account_mapping.aws_account}-${each.value.rt_name}-${local.account_mapping.region}"].id
  subnet_id      = aws_subnet.subnets["${local.account_mapping.aws_account}-${each.value.subnet_name}-${local.account_mapping.region}"].id
}

resource "aws_route_table_association" "igw_associations" {
  for_each = { for assoc in flatten([
    for rt in local.account_mapping.route_tables : [
      for igw in lookup(rt, "igw", []) : {
        rt_name  = rt.name
        igw_name = igw
      }
    ]
  ]) : "${local.account_mapping.aws_account}-${assoc.rt_name}-${local.account_mapping.region}-${assoc.igw_name}" => assoc }
  route_table_id = aws_route_table.route_tables["${local.account_mapping.aws_account}-${each.value.rt_name}-${local.account_mapping.region}"].id
  gateway_id     = aws_internet_gateway.igw[0].id
}

resource "aws_route" "routes_igw" {
  for_each = { for route in flatten([
    for rt in local.account_mapping.route_tables :
    rt.routes != null ? [
      for route in rt.routes : {
        rt_name = rt.name
        route   = route
      } if route.resource.type == "igw"
    ] : []
  ]) : "${local.account_mapping.aws_account}-${route.rt_name}-${local.account_mapping.region}-route-${replace(replace(route.route.cidr, ".", ""), "/", "")}" => route }
  route_table_id         = aws_route_table.route_tables["${local.account_mapping.aws_account}-${each.value.rt_name}-${local.account_mapping.region}"].id
  destination_cidr_block = each.value.route.cidr

  gateway_id = aws_internet_gateway.igw[0].id
}

resource "aws_route" "routes_nat_gw" {
  for_each = { for route in flatten([
    for rt in local.account_mapping.route_tables :
    rt.routes != null ? [
      for route in rt.routes : {
        rt_name = rt.name
        route   = route
      } if route.resource.type == "nat_gw"
    ] : []
  ]) : "${local.account_mapping.aws_account}-${route.rt_name}-${local.account_mapping.region}-route-${replace(replace(route.route.cidr, ".", ""), "/", "")}" => route }
  route_table_id         = aws_route_table.route_tables["${local.account_mapping.aws_account}-${each.value.rt_name}-${local.account_mapping.region}"].id
  destination_cidr_block = each.value.route.cidr

  nat_gateway_id = aws_nat_gateway.nat_gws["${local.account_mapping.aws_account}-${each.value.route.resource.name}-${local.account_mapping.region}"].id
}

resource "aws_route" "routes_eni" {
  for_each = {
    for route in flatten([
      for rt in local.account_mapping.route_tables :
      rt.routes != null ? [
        for route in rt.routes : {
          rt_name = rt.name
          route   = route
        } if route.resource.type == "eni"
      ] : []
    ]) : "${local.account_mapping.aws_account}-${route.rt_name}-${local.account_mapping.region}-route-${replace(replace(route.route.cidr, ".", ""), "/", "")}" => route
  }
  route_table_id         = aws_route_table.route_tables["${local.account_mapping.aws_account}-${each.value.rt_name}-${local.account_mapping.region}"].id
  destination_cidr_block = each.value.route.cidr

  network_interface_id = each.value.route.resource.name
}

resource "aws_vpc_endpoint" "gateway_endpoints" {
  for_each          = { for gw_endpoint in local.account_mapping.gateway_endpoints : "${local.account_mapping.aws_account}-${local.account_mapping.vpc_cidrs.name}-${gw_endpoint.aws_service}-${local.account_mapping.region}" => gw_endpoint }
  route_table_ids   = [for rt in each.value.route_tables : aws_route_table.route_tables["${local.account_mapping.aws_account}-${rt}-${local.account_mapping.region}"].id]
  service_name      = "com.amazonaws.${local.account_mapping.region}.${each.value.aws_service}"
  vpc_id            = aws_vpc.vpc.id
  vpc_endpoint_type = "Gateway"
  tags              = merge({ Name = "${each.value.aws_service}_gw_endpoint" }, lookup(each.value, "tags", {}))
}

