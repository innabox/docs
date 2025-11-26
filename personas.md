# OSAC Personas

These are the essential personas that OSAC must target for an MVP. Many
additional personas can be identified within the solution space, some of which
will be added to this document over time as the project is ready to address
their unique use cases.

## Cloud Provider Admin

* is an associate of the Cloud Provider
* ensures that cloud services are running, including the cloud control plane
* integrates the cloud control plane with local infrastructure including specific compute hardware, DNS systems, storage solutions, etc
* handles or facilitates tenant onboarding
* uses the OSAC interfaces to manage tenant organizations
* uses the OSAC interfaces to manage resource allocation
* is a super-user of the system and can see all tenant organiations
* works with internal infrastructure owners as necessary
* manages any global catalogs of templates (VM templates, cluster templates, etc)
* ensures that all templates work with the local inrastructure

## Tenant Admin

* is an associate of a Tenant Organization
* typically does not have any relationship to other tenants of the cloud provider
* manages their organization's configuration in OSAC, including IDP
* manages users within their organization
* manages quotas within their organization
* can only see users and resources associated with their own organization
* manages organization-specific catalogs of templates

## Tenant User

* is an associate of a Tenant Organization
* can utilize templates from global and organization-specific catalogs
* self-service provisions cloud resources for use by themself or their team
* manages the full lifecycle of cloud resourses
* can see quota utilization that would apply to them
* may prefer click-ops, but wants an API and CLI for optional automation