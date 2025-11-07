# Cluster Fulfillment

Cluster fulfillment is the process of provisioning OpenShift clusters on-demand
for tenants. OSAC uses a template-based approach that enables Cloud Service
Providers (CSPs) to offer standardized cluster configurations while maintaining
flexibility to customize the underlying infrastructure and deployment process.

## Overview

Cluster fulfillment in OSAC leverages Red Hat Advanced Cluster Management
(RHACM) to deploy OpenShift clusters using the Hosted Control Planes
architecture. This approach allows control plane components to run as pods on a
Management Cluster while worker nodes can run on bare metal servers or virtual
machines.

The cluster fulfillment workflow follows the general pattern described in the
[main architecture document](README.md#workflow), with specific implementations
for cluster provisioning:

1. A cluster request is submitted to the Fulfillment Service API
2. The Fulfillment Service schedules the request to a Management Cluster
3. The OSAC Controller on the Management Cluster processes the request and triggers Event Driven Ansible
4. Ansible Automation Platform executes the cluster provisioning workflow using template-based automation
5. Status is continuously synchronized back through the controller to the Fulfillment Service

## Components

### Fulfillment Service - Cluster API

The Fulfillment Service provides gRPC and REST APIs for managing cluster
lifecycle operations:

**API Operations** (`fulfillment-service/proto/private/v1/clusters_service.proto`):
- `Create`: Request a new cluster deployment
- `Get`: Retrieve cluster details and status
- `List`: List all clusters for a tenant
- `Update`: Modify cluster configuration
- `Delete`: Request cluster deletion

**Cluster Request Model** (`fulfillment-service/proto/private/v1/cluster_type.proto`):

A cluster request includes:
- `template`: The cluster template ID (e.g., "ocp_4_17_small")
- `template_parameters`: A map of parameters specific to the selected template
- `node_sets`: Specifications for worker node groups, each containing:
  - `host_class`: The resource class for nodes (determines hardware characteristics)
  - `size`: Number of nodes in the node set
  - `name`: Identifier for the node set

**Cluster Status**:

The cluster status provides real-time information about the deployment:
- `state`: Overall cluster state (PROGRESSING, READY, FAILED, DEGRADED)
- `conditions`: Detailed conditions tracking specific aspects of the cluster
- `api_url`: Kubernetes API endpoint for the provisioned cluster
- `console_url`: OpenShift web console URL
- `hub`: The Management Cluster ID where the cluster is hosted

### Management Cluster Scheduling

The Fulfillment Service implements a scheduling algorithm to select an
appropriate Management Cluster for each request
(`fulfillment-service/internal/controllers/cluster/cluster_reconciler_function.go`):

1. **Hub Selection**: Currently uses random selection from available Management Clusters. Future enhancements may consider:
   - Capacity and resource availability
   - Geographic or availability zone preferences
   - Load balancing across hubs
   - Tenant affinity rules

2. **ClusterOrder Creation**: Once a Management Cluster is selected, the Fulfillment Service creates a `ClusterOrder` custom resource in a tenant-specific namespace. This object contains:
   - The selected template ID
   - Template parameters
   - Node requests translated from the node sets specification

The ClusterOrder serves as the bridge between the Fulfillment Service and the
OSAC Controller running on the Management Cluster.

### OSAC Controller - ClusterOrder Processing

The OSAC Controller is a Kubernetes controller running on each Management
Cluster that reconciles ClusterOrder resources
(`cloudkit-controller/internal/controller/clusterorder_controller.go`).

**ClusterOrder Custom Resource** (`cloudkit-controller/api/v1alpha1/clusterorder_types.go`):

The ClusterOrder CRD defines:
- `TemplateID`: Identifies which cluster template to use
- `TemplateParameters`: JSON-encoded map of template-specific parameters
- `NodeRequests`: Array of node request objects specifying resource class and quantity

**Reconciliation Loop**:

When a ClusterOrder is created or updated, the controller performs these steps:

1. **Status Initialization**: Sets the phase to "Progressing" and initializes status conditions

2. **Infrastructure Preparation**: Creates prerequisite Kubernetes objects:
   - **Namespace**: A dedicated namespace for the cluster (typically named after the cluster ID)
   - **ServiceAccount**: Identity for cluster-related automation
   - **RoleBindings**: RBAC permissions for the service account to manage cluster resources

3. **EDA Webhook Trigger**: Calls the Event Driven Ansible webhook endpoint to initiate cluster provisioning:
   - The webhook payload includes the complete ClusterOrder specification.

4. **HostedCluster Monitoring**: After the webhook is triggered, the controller watches for a HostedCluster resource (created by the Ansible automation) and monitors its conditions:
   - Waits for the control plane to become available
   - Monitors that the cluster is not degraded
   - Tracks node pool readiness

5. **Status Synchronization**: Continuously updates the ClusterOrder status based on the HostedCluster state, including:
   - Phase transitions (Progressing → Ready or Failed)
   - Condition updates
   - Cluster reference information (namespace, resource names)

6. **Deletion Handling**: When a ClusterOrder is deleted:
   - Triggers the deletion webhook to EDA
   - Ensures all associated cluster resources are cleaned up
   - Uses finalizers to prevent premature deletion

### Ansible Automation Platform - Cluster Provisioning

Event Driven Ansible (EDA) running on AAP receives webhook events from the OSAC
Controller and orchestrates the actual cluster provisioning.

**EDA Rulebook** (`cloudkit-aap/rulebooks/cluster_fulfillment.yml`):

The rulebook listens on port 5000 and defines rules for cluster lifecycle events:
- Endpoint: `create-hosted-cluster` → Triggers the cluster creation workflow
- Endpoint: `delete-hosted-cluster` → Triggers the cluster deletion job

When triggered, EDA launches the appropriate workflow template in AAP.

**Cluster Creation Playbook** (`cloudkit-aap/playbook_cloudkit_create_hosted_cluster.yml`):

The main cluster creation workflow consists of these phases:

1. **Retrieve Cluster Order Details**:
   - Fetches the ClusterOrder object from Kubernetes
   - Generates a unique lock holder ID to prevent concurrent modifications
   - Applies default cluster settings via the `cloudkit.service.cluster_settings` role

2. **Infrastructure Preparation**:
   - Extracts template information from the ClusterOrder
   - Determines the working namespace
   - Acquires a cluster lock to ensure safe concurrent operations
   - Adds an infrastructure finalizer to the ClusterOrder to track cleanup

3. **Template Execution**:
   - Dynamically includes the selected cluster template's `install` tasks
   - Templates are Ansible roles located in `cloudkit-aap/collections/ansible_collections/cloudkit/templates/roles/`
   - Each template provides a standardized interface while allowing customization of the underlying implementation

4. **Cluster Infrastructure Creation**:
   - The `cloudkit.service.cluster_infra` role manages the hosted cluster lifecycle
   - Creates or updates a HostedCluster resource
   - Provisions worker nodes according to the node requests specification
   - Configures networking, ingress, and external access

5. **Status Updates**:
   - Updates the ClusterOrder status throughout the provisioning process
   - Reports any errors or failures back to the controller
   - Marks the cluster as ready once all components are operational

## Cluster Templates

Cluster templates are implemented as Ansible roles that define how clusters are
provisioned. Each template:

- Accepts standardized parameters (defined via role argument validation)
- Implements an `install.yaml` tasks file that performs the provisioning
- Can customize cluster configuration, pre-installed software, and infrastructure details

**Template Metadata**:

Each template defines metadata that helps users understand the template and its
requirements:
- `title`: Human-readable name
- `description`: Explanation of what the template provides
- `default_node_requirements`: Default worker node configuration
- `allowed_resource_classes`: Which host classes are compatible with this template

CSPs can create custom templates to offer differentiated cluster configurations, such as:
- Clusters with specific software pre-installed (monitoring, security tools, etc.)
- Different versions of OpenShift
- Specialized hardware configurations
- Compliance-specific settings

## Worker Node Provisioning

Worker nodes for hosted clusters can be provisioned in multiple ways depending
on the CSP's infrastructure:

**Bare Metal Workers**:
When worker nodes are provisioned on bare metal:
1. The template includes tasks to allocate physical servers from inventory
2. Network isolation is applied (L2/L3 networking, VLANs, etc.)
3. Nodes are joined to the hosted control plane

**Virtual Machine Workers**:
When worker nodes are VMs on OpenShift Virtualization:
1. VM resources are created on the Management Cluster
2. The template defines VM specifications (CPU, memory, storage)
3. VMs are automatically provisioned and configured
4. Nodes join the hosted control plane

## Infrastructure Components

The cluster provisioning workflow integrates with several infrastructure components:

**Hosted Control Planes (Hypershift)**:
- Control plane components (API server, controller manager, scheduler, etcd) run as pods on the Management Cluster
- This architecture enables:
  - Faster cluster provisioning (no need to boot control plane nodes)
  - Lower resource overhead per cluster
  - Easier/faster upgrades and maintenance

**Networking**:
- Each cluster receives isolated network configurations
- Ingress is configured using MetalLB or another load balancer solution (`cloudkit.service.metallb_ingress` role)
- External access is configured to expose the API and console endpoints
- Worker nodes are connected to the appropriate networks based on template configuration

**Storage**:
- Templates can specify storage classes for persistent volumes
- Both local and remote storage backends are supported
- CSPs can customize storage options per template

**Identity and Access**:
- Each cluster can be configured with an identity provider
- RBAC configurations can be pre-applied by templates
- Service accounts are created for cluster administration

## Status Tracking and Reporting

Cluster status flows through multiple levels:

1. **Hypershift HostedCluster Status**: The source of truth for control plane state
   - Tracks control plane availability
   - Reports degraded conditions
   - Provides version information

2. **ClusterOrder Status**: Maintained by the OSAC Controller
   - Aggregates HostedCluster and NodePool status
   - Tracks provisioning phase (Progressing/Ready/Failed/Deleting)
   - Includes detailed conditions for troubleshooting

3. **Fulfillment Service Cluster Status**: Synchronized from ClusterOrder
   - Provides tenant-facing status information
   - Includes API and console URLs when ready
   - Maintains conditions visible through the API

**Key Status Conditions**:
- `ClusterAvailable`: Control plane is operational
- `NodesReady`: Worker nodes have joined and are ready
- `InfrastructureReady`: Supporting infrastructure (networking, storage) is configured
- `TemplateApplied`: Template-specific configuration has been applied

## Cluster Deletion

When a cluster deletion is requested:

1. **Fulfillment Service**: Updates the ClusterOrder to trigger deletion
2. **OSAC Controller**: Detects deletion and:
   - Triggers the deletion webhook to EDA
   - Sets ClusterOrder phase to "Deleting"
3. **Ansible Automation**: Executes the deletion playbook which:
   - Removes the HostedCluster resource
   - Deallocates worker nodes (shuts down VMs or releases bare metal)
   - Cleans up networking and storage resources
   - Removes the cluster namespace
4. **OSAC Controller**: Finalizes ClusterOrder deletion after all resources are cleaned up

## Scalability and Performance

The cluster fulfillment system is designed for scale:

**Management Cluster Capacity**:
- Each Management Cluster can host a large number of hosted control planes
- Sizing depends on worker node density and control plane resource requirements

**Provisioning Throughput**:
- Multiple clusters can be provisioned concurrently on a single Management Cluster
- The cluster lock mechanism prevents resource conflicts
- EDA webhook rate limiting prevents overwhelming AAP

**Horizontal Scaling**:
- Additional Management Clusters can be added to increase total capacity
- The Fulfillment Service load balances across available Management Clusters
- Each Management Cluster operates independently

## Customization and Extension

CSPs can customize cluster fulfillment in several ways:

**Custom Templates**: Create new Ansible role-based templates that:
- Pre-install required software or operators
- Apply specific security policies
- Configure clusters for specialized workloads (AI/ML, edge, etc.)
- Integrate with CSP-specific infrastructure

**Infrastructure Adapters**: Customize how worker nodes are provisioned:
- Integrate with different inventory systems
- Adapt to proprietary bare metal provisioning systems

**Workflow Extensions**: Add pre- or post-provisioning steps:
- Backup and disaster recovery setup
- Monitoring and observability configuration
- Compliance scanning and hardening

**Template Parameters**: Expose configuration options to end users:
- OpenShift version selection
- Add-on operator selection
- Resource quota settings
- Backup and retention policies

By leveraging the flexibility of Ansible and the declarative nature of
Kubernetes operators, OSAC's cluster fulfillment provides a powerful foundation
for CSPs to deliver OpenShift clusters as a service.
