# The laptop's infrastructure tools, pinned, in one image: Terraform, and the OVH CLI its local-exec calls.
# Built by `make tools`; every OVH host target runs in it, so nothing but Docker is installed for them.
FROM ovhcom/ovhcloud-cli:v0.15.0 AS ovhcloud

FROM hashicorp/terraform:1.16.5
RUN apk add --no-cache jq
COPY --from=ovhcloud /usr/local/bin/ovhcloud /usr/local/bin/ovhcloud
