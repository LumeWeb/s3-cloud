# AWS Marketplace Submission Checklist — Pinner.xyz S3 Server

## Seller prerequisites
- [ ] AWS Marketplace seller registration complete.
- [ ] Access to AWS Marketplace Management Portal (AMMP).

## AMI requirements
- [ ] AMI built from `deploy/aws/template.pkr.hcl` in `us-east-1` and owned by seller account.
- [ ] AMI uses HVM virtualization, 64-bit architecture, EBS-backed root device.
- [ ] `PasswordAuthentication no` and `PermitRootLogin no` enforced in `sshd_config`.
- [ ] Authorized keys removed; SSH host keys removed; cloud-init logs cleaned.
- [ ] AMI passes AMMP "Test 'Add Version"" scan with no critical findings.

## CloudFormation template requirements
- [ ] Template uploaded to AMMP as part of the AMI with CloudFormation delivery option.
- [ ] No default CIDR allowing public SSH (`AllowedSSHCIDR` defaults to empty).
- [ ] Application CIDR is parameterised (`AllowedAppCIDR`).
- [ ] S3 credentials use `NoEcho: true` and are not echoed in outputs.
- [ ] `ImageId` references a template parameter (`AWS::EC2::Image::Id`).
- [ ] External dependency on GHCR disclosed in usage instructions.

## Listing content
- [ ] Product title, description, and `Description` field of the AMI match.
- [ ] Usage instructions uploaded (`deploy/aws/marketplace/USAGE_INSTRUCTIONS.md`).
- [ ] Security group recommendations documented (`deploy/aws/marketplace/SECURITY_GROUPS.md`).
- [ ] External dependency (GHCR auto-update) disclosed in usage instructions.
- [ ] Architecture diagram uploaded to S3 and URL provided in listing (if required).

## Post-submission
- [ ] Product released to **Limited** state; allowlist the test account(s).
- [ ] Launch an instance from the Limited listing and verify end-to-end S3 API access.
- [ ] Request **Public** visibility; Seller Operations review takes 7–10 business days.
