variable "region" {
  type    = string
  default = "ap-southeast-2"
}
variable "cluster_name" {
  type    = string
  default = "sideproj-eks"
}
variable "kubernetes_version" {
  type    = string
  default = "1.30"
}
variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}
variable "desired_size" {
  type    = number
  default = 2
}
variable "min_size" {
  type    = number
  default = 1
}
variable "max_size" {
  type    = number
  default = 4
}