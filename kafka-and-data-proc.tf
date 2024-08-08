# Infrastructure for setting up integration between the Data Proc and Managed Service for Apache Kafka® clusters
#
# RU: https://yandex.cloud/ru/docs/data-proc/tutorials/kafka
# EN: https://yandex.cloud/en/docs/data-proc/tutorials/kafka
#
# Set the configuration of the Data Proc and Managed Service for Apache Kafka® clusters

# Specify the following settings:
locals {
  folder_id  = "" # Your cloud folder ID, the same as for your provider
  dp_ssh_key = "" # Аbsolute path to an SSH public key for the Data Proc cluster

  # The following settings are predefined. Change them only if necessary.
  network_name          = "dataproc-network" # Name of the network
  nat_name              = "dataproc-nat" # Name of the NAT gateway
  subnet_name           = "dataproc-subnet-b" # Name of the subnet
  sa_name               = "dataproc-sa" # Name of the service account
  bucket_name           = "dataproc-bucket-8097865" # Name of the Object Storage bucket
  dataproc_cluster_name = "dataproc-cluster" # Name of the Data Proc cluster
  kafka_cluster_name    = "dataproc-kafka" # Name of the Managed Service for Apache Kafka® cluster
  kafka_username        = "user1" # Apache Kafka® username.
  kafka_password        = "password1" # Password of the Apache Kafka® user.
  topic_name            = "dataproc-kafka-topic" # Name of the Apache Kafka® topic
}

resource "yandex_vpc_network" "dataproc_network" {
  description = "Network for Data Proc and Managed Service for Apache Kafka®"
  name        = local.network_name
}

# NAT gateway for Data Proc
resource "yandex_vpc_gateway" "dataproc_nat" {
  name = local.nat_name
  shared_egress_gateway {}
}

# Routing table for Data Proc
resource "yandex_vpc_route_table" "dataproc_rt" {
  network_id = yandex_vpc_network.dataproc_network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.dataproc_nat.id
  }
}

resource "yandex_vpc_subnet" "dataproc_subnet_b" {
  description    = "Subnet for Data Proc and Managed Service for Apache Kafka®"
  name           = local.subnet_name
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.dataproc_network.id
  v4_cidr_blocks = ["10.140.0.0/24"]
  route_table_id = yandex_vpc_route_table.dataproc_rt.id
}

resource "yandex_vpc_security_group" "dataproc_security_group" {
  description = "Security group for the Data Proc and Managed Service for Apache Kafka® clusters"
  network_id  = yandex_vpc_network.dataproc_network.id

  ingress {
    description       = "Allow any incoming traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  ingress {
    description    = "Allow access to NTP servers for time syncing"
    protocol       = "UDP"
    port           = 123
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description       = "Allow any outgoing traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  egress {
    description    = "Allow connections to the HTTPS port from any IP address"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow access to NTP servers for time syncing"
    protocol       = "UDP"
    port           = 123
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_iam_service_account" "dataproc_sa" {
  description = "Service account to manage the Data Proc cluster"
  name        = local.sa_name
}

# Assign the storage.admin role to the Data Proc service account
resource "yandex_resourcemanager_folder_iam_binding" "storage_admin" {
  folder_id = local.folder_id
  role      = "storage.admin"
  members   = ["serviceAccount:${yandex_iam_service_account.dataproc_sa.id}"]
}

# Assign the dataproc.agent role to the Data Proc service account
resource "yandex_resourcemanager_folder_iam_binding" "dataproc_agent" {
  folder_id = local.folder_id
  role      = "dataproc.agent"
  members   = ["serviceAccount:${yandex_iam_service_account.dataproc_sa.id}"]
}

# Assign the storage.uploader role to the Data Proc service account
resource "yandex_resourcemanager_folder_iam_binding" "dataproc_user" {
  folder_id = local.folder_id
  role      = "dataproc.user"
  members   = ["serviceAccount:${yandex_iam_service_account.dataproc_sa.id}"]
}

resource "yandex_iam_service_account_static_access_key" "sa_static_key" {
  description        = "Static access key for Object Storage"
  service_account_id = yandex_iam_service_account.dataproc_sa.id
}

# Use the key to create a bucket and provide the service account with full control over the bucket
resource "yandex_storage_bucket" "dataproc_bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
  bucket     = local.bucket_name

  grant {
    id = yandex_iam_service_account.dataproc_sa.id
    type        = "CanonicalUser"
    permissions = ["FULL_CONTROL"]
  }
}

resource "yandex_dataproc_cluster" "dataproc_cluster" {
  description        = "Data Proc cluster"
  depends_on         = [yandex_resourcemanager_folder_iam_binding.storage_admin, yandex_resourcemanager_folder_iam_binding.dataproc_agent, yandex_resourcemanager_folder_iam_binding.dataproc_user]
  bucket             = yandex_storage_bucket.dataproc_bucket.id
  security_group_ids = [yandex_vpc_security_group.dataproc_security_group.id]
  name               = local.dataproc_cluster_name
  service_account_id = yandex_iam_service_account.dataproc_sa.id
  zone_id            = "ru-central1-b"
  ui_proxy           = true

  cluster_config {
    version_id = "2.1"

    hadoop {
      services        = ["HDFS", "LIVY", "SPARK", "TEZ", "YARN"]
      ssh_public_keys = [file(local.dp_ssh_key)]
    }

    subcluster_spec {
      name = "main"
      role = "MASTERNODE"
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB of RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id        = yandex_vpc_subnet.dataproc_subnet_b.id
      hosts_count      = 1
    }

    subcluster_spec {
      name = "data"
      role = "DATANODE"
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB of RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id   = yandex_vpc_subnet.dataproc_subnet_b.id
      hosts_count = 1
    }

    subcluster_spec {
      name = "compute"
      role = "COMPUTENODE"
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB of RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id   = yandex_vpc_subnet.dataproc_subnet_b.id
      hosts_count = 1
    }
  }
}

resource "yandex_mdb_kafka_cluster" "kafka_cluster" {
  description        = "Managed Service for Apache Kafka® cluster"
  environment        = "PRODUCTION"
  name               = local.kafka_cluster_name
  network_id         = yandex_vpc_network.dataproc_network.id
  security_group_ids = [yandex_vpc_security_group.dataproc_security_group.id]

  config {
    brokers_count    = 1
    version          = "3.5"
    kafka {
      resources {
        disk_size          = 10 # GB
        disk_type_id       = "network-ssd"
        resource_preset_id = "s2.micro"
      }
    }

    zones = [
      "ru-central1-b"
    ]
  }
}

# Apache Kafka® user
resource "yandex_mdb_kafka_user" "kafka_user" {
  cluster_id = yandex_mdb_kafka_cluster.kafka_cluster.id
  name       = local.kafka_username
  password   = local.kafka_password
}

# Apache Kafka® topic
resource "yandex_mdb_kafka_topic" "dataproc_kafka_topic" {
  cluster_id         = yandex_mdb_kafka_cluster.kafka_cluster.id
  name               = local.topic_name
  partitions         = 1
  replication_factor = 1
}