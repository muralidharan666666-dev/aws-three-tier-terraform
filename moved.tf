# ---------------------------------------------------------------------------
# These resources moved from the root into modules/vpc. Each block tells
# Terraform "same object, new address", so it renames them in state instead
# of destroying and recreating them.
#
# Safe to delete later, once every state that had the old addresses has
# been applied with these in place.
# ---------------------------------------------------------------------------

moved {
  from = aws_vpc.main
  to   = module.vpc.aws_vpc.this
}

moved {
  from = aws_internet_gateway.main
  to   = module.vpc.aws_internet_gateway.this
}

moved {
  from = aws_subnet.public
  to   = module.vpc.aws_subnet.public
}

moved {
  from = aws_subnet.private_app
  to   = module.vpc.aws_subnet.private_app
}

moved {
  from = aws_subnet.private_db
  to   = module.vpc.aws_subnet.private_db
}

moved {
  from = aws_eip.nat
  to   = module.vpc.aws_eip.nat
}

moved {
  from = aws_nat_gateway.main
  to   = module.vpc.aws_nat_gateway.this
}

moved {
  from = aws_route_table.public
  to   = module.vpc.aws_route_table.public
}

moved {
  from = aws_route_table.private
  to   = module.vpc.aws_route_table.private
}

moved {
  from = aws_route_table_association.public
  to   = module.vpc.aws_route_table_association.public
}

moved {
  from = aws_route_table_association.private_app
  to   = module.vpc.aws_route_table_association.private_app
}

moved {
  from = aws_route_table_association.private_db
  to   = module.vpc.aws_route_table_association.private_db
}

moved {
  from = aws_default_security_group.default
  to   = module.vpc.aws_default_security_group.this
}
