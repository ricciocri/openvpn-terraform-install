data "aws_ami" "amazon_linux_2" {
  most_recent = true

  filter {
    name   = "name"
    values = [var.aws_ami_name]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "block-device-mapping.volume-type"
    values = [var.aws_ami_vol_type]
  }

  filter {
    name   = "virtualization-type"
    values = [var.aws_ami_virt_type]
  }

  owners = ["amazon"]
}

resource "aws_key_pair" "openvpn" {
  key_name   = var.ssh_private_key_file
  public_key = file("${path.module}/${var.ssh_public_key_file}")
}

resource "aws_instance" "openvpn" {
  ami                         = data.aws_ami.amazon_linux_2.id
  associate_public_ip_address = true
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.openvpn.key_name
  subnet_id                   = aws_subnet.openvpn.id

  vpc_security_group_ids = [
    aws_security_group.openvpn.id,
    aws_security_group.ssh_from_local.id,
  ]

  root_block_device {
    volume_type           = var.aws_ec2_vol_type
    volume_size           = var.instance_root_block_device_volume_size
    encrypted             = var.aws_ami_vol_encrypted 
    delete_on_termination = true
  }
  disable_api_termination = var.aws_ami_protection_on_termination
  tags = {
    Name        = var.tag_name
    Provisioner = "Terraform"
  }
}

resource "aws_eip" "openvpn_eip" {
  instance = aws_instance.openvpn.id 
  tags = {
    Name = "OpenVPN EIP"
  }
}



resource "null_resource" "openvpn_bootstrap" {
  connection {
    type        = "ssh"
    host        = aws_eip.openvpn_eip.public_ip
    user        = var.ec2_username
    port        = "22"
    private_key = file("${path.module}/${var.ssh_private_key_file}")
    agent       = false
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum update -y",
      "curl -O ${var.openvpn_install_script_location}",
      "chmod +x openvpn-install.sh",
      <<EOT
      sudo AUTO_INSTALL=y \
           APPROVE_IP=${aws_eip.openvpn_eip.public_ip} \
           ENDPOINT=${var.use_public_dns ? aws_eip.openvpn_eip.public_dns : aws_eip.openvpn_eip.public_ip} \
           PORT=${var.ovpn_port} \
           CLIENT=${var.ovpn_client} \
           CIPHER=${var.ovpn_cipher} \
           TLS_SIG=${var.ovpn_tls_sig} \
           SRV_BUFF_SIZE_MAX=${var.ovpn_srv_buff_size_max} \
           SRV_BUFF_SIZE_DEFAULT=${var.ovpn_srv_buff_size_default} \
           CLIENT_BUFF_SIZE=${var.ovpn_client_buff_size} \
           DNS=${var.ovpn_dns}  \
           IPV6_SUPPORT=n \
           PORT_CHOICE=2 \
           PROTOCOL_CHOICE=1 \
           COMPRESSION_ENABLED=n \
           PASS=1 \
           CUSTOMIZE_ENC=n \
           ./openvpn-install.sh
      
EOT
      ,
    ]
  }
}

resource "null_resource" "openvpn_update_users_script" {
  depends_on = [null_resource.openvpn_bootstrap]

  triggers = {
    ovpn_users = join(" ", var.ovpn_users)
  }

  connection {
    type        = "ssh"
    host        = aws_eip.openvpn_eip.public_ip
    user        = var.ec2_username
    port        = "22"
    private_key = file("${path.module}/${var.ssh_private_key_file}")
    agent       = false
  }

  provisioner "file" {
    source      = "${path.module}/scripts/update_users.sh"
    destination = "/home/${var.ec2_username}/update_users.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x ~${var.ec2_username}/update_users.sh",
      "sudo ~${var.ec2_username}/update_users.sh ${join(" ", var.ovpn_users)}",
    ]
  }
}

resource "null_resource" "openvpn_download_configurations" {
  depends_on = [null_resource.openvpn_update_users_script]

  triggers = {
    ovpn_users = join(" ", var.ovpn_users)
  }

  provisioner "local-exec" {
    command = <<EOT
    mkdir -p ${var.ovpn_config_directory};
    scp -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i ${var.ssh_private_key_file} ${var.ec2_username}@${aws_eip.openvpn_eip.public_ip}:/home/${var.ec2_username}/*.ovpn ${var.ovpn_config_directory}/
    
EOT

  }
}

