provider "aws" {
  region = var.region
}



# vairables

variable region {}
variable vpc-primary-cidr {}
variable vpc-name {}
variable type-worker {}
variable type-master {}
variable cluster-id {}
variable ami-id {}


locals {
  azs_count = length(data.aws_availability_zones.available.names)
}


# data sources

data "aws_availability_zones" "available" {
  state = "available"
}

data "http" "myip" {
  url = "https://ipv4.icanhazip.com"
}


# resources

# create a vpc
resource "aws_vpc" "self-managed-k8s" {
  cidr_block = var.vpc-primary-cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = var.vpc-name
  }
}

# create a public subnets for master nodes
resource "aws_subnet" "master-public" {
  count = local.azs_count
  
  vpc_id = aws_vpc.self-managed-k8s.id
  cidr_block = cidrsubnet(aws_vpc.self-managed-k8s.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "master-public-${count.index + 1}"
  }
}

# create a public subnets for worker nodes
resource "aws_subnet" "worker-public" {
  count = local.azs_count
  
  vpc_id = aws_vpc.self-managed-k8s.id
    
  cidr_block = cidrsubnet(aws_vpc.self-managed-k8s.cidr_block, 8, count.index + local.azs_count)
  
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "worker-public-${count.index + 1}"
  }
}

# create an igw 
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.self-managed-k8s.id
  tags = {
    Name = "k8s-cluster${var.cluster-id}"
  }
}

# create a public route table 
resource "aws_route_table" "public-rtb" {
  vpc_id = aws_vpc.self-managed-k8s.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id   
  }
  tags = {
    Name = "public-rtb"
  }
}

# association between master public subnets and route table
resource "aws_route_table_association" "rtb-association-master" {
  count = local.azs_count
  subnet_id = aws_subnet.master-public[count.index].id
  route_table_id  = aws_route_table.public-rtb.id
}

# association between worker public subnets and route table
resource "aws_route_table_association" "rtb-association-worker" {
  count = local.azs_count
  subnet_id = aws_subnet.worker-public[count.index].id
  route_table_id  = aws_route_table.public-rtb.id
}

# create security-group
resource "aws_security_group" "basic" {
  name = "basic" 
  description = "basic protection"
  vpc_id = aws_vpc.self-managed-k8s.id

  egress {
    description = "internet access"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "whitelist"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["${chomp(data.http.myip.body)}/32"]
  }

  ingress {
    description = "cluster node interconnectivity"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [aws_vpc.self-managed-k8s.cidr_block]
  }

  tags = {
    Name = "basic"
  }
}

resource "tls_private_key" "tls-rsa-4k" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "key" {
  key_name   = "k8s-cluster${var.cluster-id}"
  public_key = tls_private_key.tls-rsa-4k.public_key_openssh
}

# create 1x ec2 instance in k8s cluster
resource "aws_instance" "master" {
  count = 1
  ami = var.ami-id
  instance_type = var.type-master
  availability_zone = data.aws_availability_zones.available.names[count.index]
  subnet_id = aws_subnet.master-public[count.index].id

  vpc_security_group_ids = [aws_security_group.basic.id]
  associate_public_ip_address = true
  key_name = aws_key_pair.key.id
  tags = {
    Name = "master-${count.index + 1}"
  }
}
 
# create 3x ec2 instance, two masters and three workers in k8s cluster
resource "aws_instance" "worker" {
  count = local.azs_count
  ami = var.ami-id
  instance_type = var.type-worker
  availability_zone = data.aws_availability_zones.available.names[count.index]
  subnet_id = aws_subnet.worker-public[count.index].id
  vpc_security_group_ids = [aws_security_group.basic.id]
  associate_public_ip_address = true
  key_name = aws_key_pair.key.id
  tags = {
    Name = "worker-${count.index + 1}"
  }
}

# display public ips allocated to insatnces
output "master-public-ips" {
  description = "Public IPv4 allocated to cluster master nodes"
  value = [for node in aws_instance.master : node.public_ip]
}

output "worker_public_ips" {
  description = "Public IPv4 allocated to cluster master nodes"
  value = [for node in aws_instance.worker : node.public_ip]
}

# write key data to local
resource "local_file" "pem-file" {
  filename = "./k8s-cluster-${var.cluster-id}.pem"
  content  = tls_private_key.tls-rsa-4k.private_key_pem
  provisioner "local-exec" {
    command = "chmod 400 ./k8s-cluster-${var.cluster-id}.pem"
  }
}


# write public ips to ansible inventory file
resource "local_file" "inventory" {
  filename = "setup_k8s/hosts"
  content  = <<EOT
#[${aws_vpc.self-managed-k8s.tags.Name}]

[k8s-master]
%{ for node in aws_instance.master ~}
${ node.tags.Name } ansible_host=${ node.public_ip } ansible_user=ubuntu
%{ endfor ~}

[k8s-worker]
%{ for node in aws_instance.worker ~}
${ node.tags.Name } ansible_host=${ node.public_ip } ansible_user=ubuntu
%{ endfor ~}

[cluster:children]
k8s-master
k8s-worker
  EOT
}