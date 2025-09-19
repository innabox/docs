# Architecture

The Open Sovereign AI Cloud (OSAC) solution gives cloud providers a complete platform
to offer self-service provisioning of a range of services and infrastructure (e.g., VMs, Bare Metal, 
OpenShift clusters, OpenShift AI, Model as a Service...) , integrated with the cloud provider’s existing infrastructure
components. It features a fulfillment workflow that is powerful enough to handle
complex cluster deployment while also being flexible enough to accommodate
future expansion into other types of deployments.

## Templates

Self-service provisioning in OSAC is built around a concept of Templates.
Whether an end user wants to provision a VM, a cluster, or something else,
they'll be presented with a selection of templates from which to choose. Upon
selecting a template, they'll provide the required input, and then the system
will proceed with a workflow to allocate the resources (e.g., computers, VMs, networks), connect those resources together, and install the required software on them.

The Cloud Service Provider (CSP) can define their own templates, including:

* What input each template requires
* What infrastructure it provisions
* How it provisions that infrastructure

Ansible makes that possible, because Ansible
[Roles](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html)
can be used as Templates. Metadata such as [argument
validation](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#role-argument-validation)
describes how to use a template, while the contents of the Role itself codify
the implementation of provisioning.

Provisioning any kind of compute infrastructure can involve many different systems, such as:

* DNS
* Network fabric
* Hardware inventory
* Hardware management
* Virtualization platform
* Application deployment

Ansible's huge ecosystem of content can already interact with and automate the
vast majority of systems that would be used by a cloud provider. By utilizing
ansible for defining the template and the details of how infrastructure gets
provisioned, each cloud provider gets the opportunity to customize templates to
use their chosen infrastructure systems.

## Management Clusters

A Management Cluster is an OpenShift cluster that includes a specific set of
management tooling and that has access to a pool of provisionable compute
resources.

Each Management Cluster includes all of the resources and tooling that is
necessary to provision and sustain the infrastructure requested by end users. A
single Management Cluster may be treated as a failure domain or availability
zone.

Management clusters include the following software:

* [Red Hat Advanced Cluster Management](https://www.redhat.com/en/technologies/management/advanced-cluster-management): provision and manage clusters, especially using Hosted Control Planes.
* [OpenShift Virtualization](https://www.redhat.com/en/technologies/cloud-computing/openshift/virtualization): provision and manage VMs.
* [Ansible Automation Platform](https://www.redhat.com/en/technologies/management/ansible): Event Driven Ansible (EDA) to execute provisioning and management workflows.

## Fulfillment

The Fulfillment Service provides a single API that enables a CSP to access the
wide range of capabilities needed to provision infrastructure on-demand. It does
so by providing a gRPC- and/or REST-based API that allows end-users to create fulfillment
requests. Upon receiving a request,it then conveys that request to a Management
Cluster where that request can be fulfilled by a set of k8s controllers.

The design of the Fulfillment Service can be understood through three major
components: the core Fulfillment Service; the CloudKit Controller; and Ansible
Automation Platform (AAP). The CloudKit Controller and AAP both run on a
management cluster.

**Fulfillment Service**: Receives and tracks requests for cloud resources, such as the clusters created by Bare Metal Fulfillment and Cluster Fulfillment. Each request is scheduled onto a management cluster. The fulfillment service includes an API that can be used through REST or gRPC. The Fulfillment CLI integrates with this API; service providers may also integrate their own UIs with this API.
**Cloudkit Controller**: A Kubernetes operator running on each management cluster that watches for requests and then ensures they get fulfilled by using a combination of direct automation and delegation to Event Driven Ansible.
**Ansible Automation Platform (AAP)**: Executes the majority of provisioning steps by running the associated Templates.

The general workflow for fulfillment is as follows:

* First, the cloud provider makes a request for resources through the API, on behalf of a tenant user, having received that request through their own user interface. Alternatively the cloud provider might expose the fulfillment API directly to end users.
* The fulfillment service selects a management cluster and then places the request there with the Kubernetes CloudKit operator using Kubernetes APIs.
* The CloudKit operator then performs automated setup and triggers the third component: Ansible playbooks via Event-Driven Ansible (EDA). It then reports status back to the Fulfillment Service.
* Once the EDA webhook is triggered, AAP runs to manage the deployment. The exact automation varies and can be customized by each cloud provider’s needs.

The Fulfillment Service is intentionally modeled on the Kubernetes pattern:
providers submit a request that declares the desired state, and the CloudKit
operator reconciles the cluster to match that desired state. To put it simply, the
fulfillment API creates the request, and the Cloudkit Operator reconciles the
order. This gives the service a flexible way to achieve reconciliation that
doesn’t limit us to a specific set of APIs or tools. Because this offers a wider
application, further configuration to fit the needs of service providers is done
through Ansible Automation Platform (AAP).

The flexibility of this architecture means that, broadly speaking, there are
only two things that must happen when implementing a fulfillment workflow.

1. Define an request object that has all the attributes a user needs to specify their desired outcome. For cluster fulfillment, that's simply a template and template parameters.
2. Create the playbooks that reconcile the request. For cluster fulfillment, those playbooks call the OpenShift provisioning APIs, as well as our initial implementation of bare metal/L2/L3 workflows.

Details of specific fulfillment types are specified in the following sections.

* [Cluster Fulfillment](cluster-fulfillment.md)
* [Bare Metal Server Fulfillment](bm-server-fulfillment.md)
* [VM Fulfillment](vm-fulfillment.md)

### Integration Patterns

In many cases, a CSP will use its own APIs and services to interact with
end-users, and then the CSP's systems will call the Fulfillment Service in
response to end-user actions. In those scenarios, the end-user never interacts
directly with the Fulfillment Service.

Optionally, a CSP can expose the Fulfillment Service directly to its end-users.

Either way, the Fulfillment Service has multitenancy built into its data and
operational models, and it depends on specific information in each API request
to identify the user and tenant.

### User Interfaces

OSAC includes [a command-line
utility](https://github.com/innabox/fulfillment-cli) that can be used to
interact with the API.

OSAC may also include a web UI that can be used for demos or proofs of concept.
At some point it might make sense to include a production-ready web UI that could
be used directly by CSPs, but that would require additional scope of use cases
that go beyond the initial focus of OSAC.

## Key Infrastructure Solutions

### Networking

Isolated networks are an essential element in any multi-tenant cloud. A proposal
is in progress, and details will be added in this repo upon acceptance.

### Inventory

In order to provision a variety of physical and virtual compute resources and then
make them available to a variety of tenants, the fulfillment workflow must have
a source of truth for what devices exist and how exactly they are connected.

OSAC expects to be able to utilize multiple different types of inventory source
of truth. Work is underway to determine what inventory source of truth will be
the primary focus for OSAC's reference implementation.
