# Instructions:

# Git clone terraform-provider-maas repo, build the provider, create .devenv and navigate to it
# git clone https://github.com/canonical/terraform-provider-maas.git
# cd terraform-provider-maas/
# make install
# make create_dev_env
# cd .devenv

# Initialize terraform in the .devenv directory and run plan.
# terraform init
# terraform plan

# Run apply to enlist, and commission host machines and DPUs in MAAS.
# terraform apply

# (optional) This is needed to put all host machines and DPU in Ready state to be available to Juju for consumption.
# terraform destroy -target maas_instance.dpu_deployment -target maas_instance.host_deployment

terraform {
  required_providers {
    maas = {
      source  = "registry.terraform.io/canonical/maas"
      version = "=1.0.1"
    }
  }
}

provider "maas" {
  api_version         = "2.0"
  api_key             = var.maas_api_key
  api_url             = var.maas_api_url
  installation_method = "snap"
}

variable "maas_snap_channel" {
  description = "The MAAS snap channel to use for the local-exec provisioner"
  type        = string
  default     = "3.7/stable"
}

variable "maas_api_url" {
  description = "The MAAS API URL"
  type        = string
  default     = "http://10.10.30.30:5240/MAAS/"
}

variable "maas_api_key" {
  description = "The MAAS API key"
  type        = string
  default     = "api_key_placeholder"
}

# commission host machine
resource "maas_machine" "host_machine" {
  hostname        = "host-0"
  architecture    = "amd64/generic"
  power_type      = "redfish"
  pxe_mac_address = "00:11:22:33:44:55"
  power_parameters = jsonencode({
    power_address = "10.10.10.10"
    power_user    = "admin"
    power_pass    = "insecure"
  })
  is_dpu = true
}

# deploy host machine
resource "maas_instance" "host_deployment" {
  allocate_params {
    system_id = maas_machine.host_machine.id
  }
  deploy_params {
    distro_series = "noble"
  }
}

# commission DPU
resource "maas_machine" "dpu1" {
  hostname        = "dpu-0"
  architecture    = "arm64/generic"
  min_hwe_kernel  = "hwe-22.04"
  power_type      = "redfish"
  pxe_mac_address = "00:11:22:33:44:66"
  power_parameters = jsonencode({
    power_address = "10.10.20.20",
    power_user    = "admin",
    power_pass    = "insecure",
  })
  is_dpu = true

  depends_on = [maas_instance.host_deployment]
}

# deploy DPU
resource "maas_instance" "dpu_deployment" {
  allocate_params {
    system_id = maas_machine.dpu1.id
  }
  deploy_params {
    distro_series = "noble"

    # TODO: We need support for deployment scripts, which will come with MAAS 3.8
    # TODO 2: We also need support at the gomaasclient repo
    # TODO 3: Properly compose a update firmware script.
    # scripts = [
    #   maas_node_script.update_firmware_script.name
    # ]
  }

  # After DPU deployment, we need to power cycle the host machine to ensure that the DPU is
  # properly initialized and ready for use.
  provisioner "local-exec" {
    command = <<-EOT
      snap install maas --channel=${var.maas_snap_channel}
      maas login local-exec ${var.maas_api_url} ${var.maas_api_key}

      # Power cycle the host machine and wait for it to be back online before proceeding.
      # When the host is powered on, the DPU will be available.
      maas local-exec machine power-cycle ${maas_machine.host_machine.id}
      while [[ "$(maas local-exec machine query-power-state ${maas_machine.host_machine.id} | jq -r '.state')" != "on" ]]; do
        echo "Waiting for host machine to be powered on..."
        sleep 5
      done

      maas logout local-exec
      snap remove maas --purge
    EOT
  }
}

resource "maas_node_script" "update_firmware_script" {
  script = base64encode(<<-EOF
#!/usr/bin/bash
#
# --- Start MAAS 1.0 script metadata ---
# name: %s
# title: Terraform Update Firmware Script
# script_type: deployment
# description: A script to update firmware on a DPU during deployment.
# --- End MAAS 1.0 script metadata ---
echo "Hello world!"
EOF
  )
}
