# Seed policy (FILE mode): forbid public-read ACLs on aws_s3_bucket
# resources in Terraform HCL. Documented example — adapt or delete.
package main

deny[msg] {
	some name
	bucket := input.resource.aws_s3_bucket[name]
	bucket.acl == "public-read"
	msg := sprintf("aws_s3_bucket.%s: public-read ACL is forbidden", [name])
}
