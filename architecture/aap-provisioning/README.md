# AAP Provisioning Abstraction and Direct Integration

## 1. Overview

The OSAC (Open Service Automation Cloud) Controller orchestrates infrastructure provisioning through Ansible Automation Platform (AAP). To support flexible deployment models and improve operational feedback, the controller implements a provider abstraction layer for infrastructure provisioning.

**Problem Statement:** The original Event-Driven Ansible (EDA) webhook-based approach had significant limitations:
- No job status feedback (fire-and-forget webhook calls)
- Unreliable completion signals (relied on AAP updating CR annotations)
- No visibility into job failures or progress
- Difficult to prevent orphaned cloud resources

**Solution:** The `ProvisioningProvider` interface enables multiple implementation strategies, currently supporting two providers:
1. **EDA Provider** - The legacy webhook-based approach for backward compatibility
2. **AAP Direct Provider** - A new REST API-based approach with full job lifecycle management

**Quick Comparison:**

| Feature | EDA Provider | AAP Direct Provider |
|---------|-------------|---------------------|
| Communication | Webhook (fire-and-forget) | REST API (with polling) |
| Job Status | Unknown (waits for annotations) | Real-time from AAP API |
| Job Cancellation | Not supported | Supported |
| Finalizer Management | AAP playbook sets finalizer | Operator manages finalizer |
| Crash Recovery | Limited (annotation-based) | Full (job ID persisted in CR) |
| Error Visibility | None (playbook must succeed) | Full traceback from AAP |
| Orphaned Resources | Possible | Prevented with BlockDeletionOnFailure |

For architectural context, see the [main OSAC architecture documentation](../README.md).

## 2. Architecture

### 2.1 Provider Abstraction Layer

The provisioning system is built around a provider interface that abstracts the mechanism for triggering infrastructure automation and retrieving job status. This pattern allows multiple backend implementations to coexist and be selected via configuration.

**Core Capabilities:**
- Trigger provisioning and deprovisioning operations
- Query job status for running operations
- Track job lifecycle from creation to completion
- Return job identifiers for status polling

**Job Lifecycle States:**

Jobs progress through a series of states during execution:
- **Pending** - Job created but not yet started
- **Waiting** - Waiting for resources or dependencies
- **Running** - Currently executing
- **Succeeded** - Completed successfully (terminal)
- **Failed** - Job failed (terminal)
- **Canceled** - Job was canceled before completion (terminal)
- **Unknown** - Status not recognized (non-terminal)

Terminal states (`Succeeded`, `Failed`, `Canceled`) indicate job completion. Non-terminal states require continued polling to track progress.

**Benefits of Abstraction:**
- **Swappable Implementations:** Change provisioning backend without controller code changes
- **Testability:** Mock providers for unit and integration tests
- **Flexibility:** Support different operational models (EDA vs direct API)
- **Evolution:** Migrate between providers without breaking existing deployments

![AAP Provisioning Component Diagram](images/AAP%20Direct%20Model%20-%20Component%20Diagram.png)

### 2.2 EDA Provider (Webhook-Based)

The EDA Provider implements the legacy webhook-based provisioning pattern using Event-Driven Ansible.

**Architecture Flow:**
1. Operator triggers webhook → EDA service
2. EDA receives event → launches AAP job template
3. AAP runs playbook → provisions infrastructure
4. AAP playbook adds finalizer to ComputeInstance CR
5. AAP playbook updates `cloudkit.openshift.io/reconciled-config-version` annotation
6. Operator detects annotation change → marks CR as Ready

**Key Characteristics:**
- **Fire-and-forget:** Webhook calls don't return job IDs or status
- **Passive feedback:** AAP playbook must update CR annotations for completion signals
- **Finalizer management:** AAP playbook is responsible for adding/removing finalizers
- **Job status:** Always returns `JobStateUnknown` (no direct visibility into job execution)
- **Completion detection:** Reconciler watches for annotation updates or finalizer removal

**When to Use:**
- Legacy environments with existing EDA infrastructure
- Simpler initial setup (no AAP token management)
- Backward compatibility with existing playbooks
- Lower operational complexity (no polling required)

**Configuration Requirements:**
- EDA service deployed and accessible from operator
- EDA webhooks configured for create/delete operations
- AAP job templates configured in EDA rulebook
- AAP playbooks must handle finalizer lifecycle
- AAP playbooks must set reconciled-config-version annotation

**Limitations:**
- No job failure visibility (operator can't tell if job failed vs still running)
- No progress updates during long-running jobs
- Can't cancel running jobs
- Higher risk of orphaned cloud resources on failures

![EDA Deletion Flow](images/EDA%20Model%20-%20Deletion%20During%20Provisioning.png)

### 2.3 AAP Direct Provider (REST API)

The AAP Direct Provider communicates directly with AAP's REST API to launch jobs and poll for status, providing full job lifecycle visibility.

**Architecture Flow:**
1. Operator calls AAP API → launch job template
2. AAP returns job ID → operator stores in CR status
3. Operator polls AAP API → check job status (default: 30s intervals)
4. Job completes → operator updates CR status with result
5. Operator manages finalizers based on job state

**Key Characteristics:**
- **Direct API integration:** REST calls to AAP Controller API
- **Real job tracking:** Actual AAP job IDs from job launch response
- **Active polling:** Operator polls job status at configurable intervals
- **Full lifecycle management:** Job creation, monitoring, cancellation, completion
- **Operator-managed finalizers:** No AAP playbook finalizer manipulation required
- **Job cancellation:** Can cancel running provision jobs before deprovisioning

**Job Lifecycle:**
```
Pending → Waiting → Running → (Succeeded | Failed | Canceled)
   ↓         ↓         ↓              ↓         ↓         ↓
 Poll      Poll      Poll       Terminal   Terminal  Terminal
```

**Advantages:**
- **Better feedback:** Real-time job status and error messages
- **Error visibility:** Full AAP traceback available in CR status
- **Orphaned resource prevention:** `BlockDeletionOnFailure` flag prevents CR deletion if deprovision fails
- **Progress tracking:** Can implement progress percentage in future
- **Crash recovery:** Job IDs persisted in CR survive controller restarts

**Template Auto-Detection:**

The AAP Direct Provider automatically determines whether a template is a `job_template` or `workflow_job_template` by querying AAP's API. This metadata is cached in memory for performance (see `cloudkit-operator/internal/aap/client.go`).

**Deletion Flow:**

![AAP Direct Creation](images/AAP%20Direct%20Model%20-%20Creation%20and%20Provisioning.png)

#### Deletion During Provisioning

A critical feature of the AAP Direct Provider is the ability to safely handle deletion requests while provisioning is still in progress.

**Flow:**
1. User deletes ComputeInstance while provision job is running
2. Operator checks provision job state via `isReadyForDeprovision()`
3. If provision job is non-terminal (Pending, Waiting, Running):
   - Operator calls AAP API to cancel the job
   - Sets deprovision action to `DeprovisionWaiting`
   - Controller requeues with backoff
4. On next reconciliation, checks if provision job reached terminal state
5. Once provision job is terminal (Succeeded, Failed, Canceled):
   - Operator triggers deprovision job
   - Proceeds with normal deletion flow

This prevents parallel execution of provision and deprovision jobs, which could leave infrastructure in an inconsistent state.

![AAP Direct Deletion](images/AAP%20Direct%20Model%20-%20Deletion%20During%20Provisioning.png)

## 3. Implementation Details

### 3.1 Code Organization

The provisioning abstraction is implemented across several packages in the cloudkit-operator repository:

```
cloudkit-operator/
├── internal/
│   ├── provisioning/
│   │   ├── provider.go           # ProvisioningProvider interface definitions
│   │   ├── eda_provider.go       # EDA webhook-based implementation
│   │   ├── aap_provider.go       # AAP Direct REST API implementation
│   │   ├── provider_test.go      # Interface contract tests
│   │   ├── eda_provider_test.go  # EDA provider unit tests
│   │   └── aap_provider_test.go  # AAP provider unit tests
│   ├── aap/
│   │   ├── client.go             # AAP REST API client
│   │   ├── client_test.go        # AAP client unit tests
│   │   └── types.go              # AAP API request/response types
│   └── controller/
│       ├── computeinstance_controller.go       # Controller integration
│       └── computeinstance_integration_test.go # Integration tests
```

### 3.2 Key Implementation Patterns

#### Preventing Parallel Provision/Deprovision

To ensure infrastructure consistency, the AAP Direct Provider prevents provision and deprovision jobs from running simultaneously.

**Behavior:**

Before triggering a deprovision operation, the provider checks the provision job state:
- If no provision job exists → safe to deprovision
- If provision job is in a terminal state (Succeeded, Failed, Canceled) → safe to deprovision
- If provision job is still running → attempts to cancel it first

**Cancellation Flow:**

When a deletion request arrives while provisioning is in progress:
1. Provider attempts to cancel the running provision job via AAP API
2. Returns a "waiting" status to the controller
3. Controller requeues the reconciliation
4. On next reconciliation, checks if provision job reached terminal state
5. Once provision job is terminal, deprovision can proceed

This ensures deprovision only starts after provision job reaches a terminal state, preventing conflicting operations.

#### Job Tracking in CR Status

Job information is persisted in the ComputeInstance status to enable crash recovery and provide observability.

**Status Fields:**

The ComputeInstance status tracks both provision and deprovision jobs separately:
- **provisionJob** - Tracks the current or most recent provision job
- **deprovisionJob** - Tracks the current or most recent deprovision job

Each job status includes:
- **id** - Job identifier (AAP job ID or "eda-webhook" for EDA provider)
- **state** - Current job state (Pending, Running, Succeeded, Failed, etc.)
- **message** - Human-readable status message
- **blockDeletionOnFailure** - Whether to prevent CR deletion if job fails (AAP: true, EDA: false)

**Persistence Strategy:**

Job IDs are persisted to the CR status immediately after triggering to enable crash recovery:
1. Provider triggers job and returns job ID
2. Controller immediately updates CR status with job ID
3. Status update uses retry logic to handle conflicts
4. On controller restart, existing job ID prevents duplicate job triggers

#### Idempotency Guarantees

The provider implementations ensure idempotent behavior to handle reconciliation loops safely.

**Duplicate Prevention:**

When triggered multiple times (due to reconciliation loops), the provider:
1. Checks if a job ID already exists in the CR status
2. If job exists, queries its current status instead of triggering a new job
3. If no job exists, triggers a new job and returns the job ID
4. Controller persists the job ID immediately to prevent duplicates

This prevents triggering multiple jobs for the same operation during reconciliation loops.

#### Template Auto-Detection (AAP)

The AAP Direct Provider automatically determines whether a configured template name refers to a job template or workflow template.

**Behavior:**

When launching a template:
1. Checks an in-memory cache for the template type
2. If not cached, queries AAP API to determine template type
3. Caches the result for future invocations
4. Uses the correct AAP API endpoint (job_templates or workflow_job_templates)

This allows operators to configure template names without specifying whether they're job templates or workflow templates, simplifying configuration.

## 4. Configuration

### 4.1 Provider Selection

The provisioning provider is selected via the `CLOUDKIT_PROVISIONING_PROVIDER` environment variable.

**Values:**
- `eda` - Use EDA webhook-based provider (default for backward compatibility)
- `aap` - Use AAP Direct REST API provider

**Example:**
```yaml
env:
  - name: CLOUDKIT_PROVISIONING_PROVIDER
    value: "aap"
```

### 4.2 EDA Provider Configuration

The EDA Provider requires webhook URLs for create and delete operations.

**Environment Variables:**

```yaml
env:
  - name: CLOUDKIT_PROVISIONING_PROVIDER
    value: "eda"

  # Webhook URL for provisioning (create)
  - name: CLOUDKIT_COMPUTE_INSTANCE_PROVISION_WEBHOOK
    value: "http://innabox-eda-service:5000/create-compute-instance"

  # Webhook URL for deprovisioning (delete)
  - name: CLOUDKIT_COMPUTE_INSTANCE_DEPROVISION_WEBHOOK
    value: "http://innabox-eda-service:5000/delete-compute-instance"

  # Minimum interval between webhook calls (rate limiting)
  - name: CLOUDKIT_MINIMUM_REQUEST_INTERVAL
    value: "10m"
```

**EDA Service Requirements:**
- HTTP endpoint accepting POST requests with JSON payload
- Payload format: ComputeInstance resource as JSON
- EDA rulebook configured to trigger AAP job templates
- AAP job templates must handle finalizer lifecycle

### 4.3 AAP Direct Provider Configuration

The AAP Direct Provider requires AAP API credentials and template names.

**Environment Variables:**

```yaml
env:
  - name: CLOUDKIT_PROVISIONING_PROVIDER
    value: "aap"

  # AAP Controller API base URL (must include /api/controller)
  - name: CLOUDKIT_AAP_URL
    value: "https://innabox-aap-example.apps.cluster.example.com/api/controller"

  # AAP OAuth2 token (from secret)
  - name: CLOUDKIT_AAP_TOKEN
    valueFrom:
      secretKeyRef:
        name: aap-credentials
        key: token

  # Job template name for provisioning
  - name: CLOUDKIT_AAP_PROVISION_TEMPLATE
    value: "innabox-create-compute-instance"

  # Job template name for deprovisioning
  - name: CLOUDKIT_AAP_DEPROVISION_TEMPLATE
    value: "innabox-delete-compute-instance"

  # Polling interval for job status (default: 30s)
  - name: CLOUDKIT_AAP_STATUS_POLL_INTERVAL
    value: "30s"
```

**Configuration Notes:**
- `CLOUDKIT_AAP_URL` must include the `/api/controller` suffix
- Template names can refer to either job templates or workflow templates (auto-detected)
- Poll interval affects responsiveness vs AAP API load (recommended: 30s-60s)
- Token must have permissions to launch templates and query job status

### 4.4 AAP Token Secret

The AAP OAuth2 token should be stored in a Kubernetes secret.

**Create Secret:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aap-credentials
  namespace: cloudkit-system
type: Opaque
stringData:
  token: "your-aap-oauth2-token-here"
```

**Apply Secret:**
```bash
kubectl apply -f aap-credentials-secret.yaml
```

**Obtaining AAP Token:**

Tokens can be created in the AAP UI or via API:

**Via AAP UI:**
1. Log in to AAP Controller
2. Navigate to: **Access → Users → [your-user] → Tokens**
3. Click **Add**
4. Set **Application** (create one if needed)
5. Set **Scope** to **Write**
6. Copy the generated token (shown only once)

**Via AAP API:**
```bash
curl -X POST https://aap-url/api/v2/tokens/ \
  -u username:password \
  -H "Content-Type: application/json" \
  -d '{
    "description": "cloudkit-operator token",
    "application": null,
    "scope": "write"
  }'
```

**Token Permissions:**
- Must have permission to launch configured job/workflow templates
- Must have permission to query job status
- Must have permission to cancel jobs (for AAP Direct deletion handling)

## 5. Operational Guide

### 5.1 Deploying with EDA Provider

The EDA Provider is the default and requires an EDA service deployment.

**Prerequisites:**
- EDA service deployed and accessible from cloudkit-operator
- EDA webhooks configured for create/delete operations
- AAP playbooks set up to handle EDA events
- AAP playbooks manage finalizers (add on provision, remove on deprovision)
- AAP playbooks update reconciled-config-version annotation

**Deployment Steps:**

1. **Deploy EDA Service:**
   ```bash
   # Deploy EDA service to cluster
   kubectl apply -f eda-service-deployment.yaml

   # Verify EDA service is running
   kubectl get pods -n cloudkit-system | grep eda
   ```

2. **Configure Operator:**
   ```yaml
   # config/manager/manager.yaml
   env:
     - name: CLOUDKIT_PROVISIONING_PROVIDER
       value: "eda"
     - name: CLOUDKIT_COMPUTE_INSTANCE_PROVISION_WEBHOOK
       value: "http://innabox-eda-service:5000/create-compute-instance"
     - name: CLOUDKIT_COMPUTE_INSTANCE_DEPROVISION_WEBHOOK
       value: "http://innabox-eda-service:5000/delete-compute-instance"
   ```

3. **Deploy Operator:**
   ```bash
   kubectl apply -f config/manager/manager.yaml
   ```

**Verification:**

```bash
# Check EDA service is running
kubectl get svc -n cloudkit-system innabox-eda-service

# Test EDA webhook endpoint (health check)
kubectl run -it --rm test-eda --image=curlimages/curl --restart=Never -- \
  curl -X POST http://innabox-eda-service:5000/health

# Create test ComputeInstance
cat <<EOF | kubectl apply -f -
apiVersion: cloudkit.openshift.io/v1alpha1
kind: ComputeInstance
metadata:
  name: test-ci
  namespace: default
spec:
  name: test-vm
  vcpu: 2
  memory: 4096
  disk: 40
EOF

# Watch ComputeInstance status
kubectl get computeinstance test-ci -w

# Check operator logs for webhook trigger
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep "eda-webhook"

# Verify annotation update from AAP
kubectl get computeinstance test-ci -o jsonpath='{.metadata.annotations.cloudkit\.openshift\.io/reconciled-config-version}'
```

### 5.2 Deploying with AAP Direct Provider

The AAP Direct Provider communicates directly with AAP's REST API.

**Prerequisites:**
- AAP Controller accessible from management cluster (network connectivity)
- AAP OAuth2 token with template execution permissions
- Job templates and/or workflow templates configured in AAP
- Templates must accept resource JSON in `ansible_eda.event.payload` format (for compatibility with EDA)
- Templates should NOT manage finalizers (operator handles this)

**Deployment Steps:**

1. **Create AAP Token Secret:**
   ```bash
   # Create secret with AAP token
   kubectl create secret generic aap-credentials \
     --from-literal=token="YOUR_AAP_TOKEN_HERE" \
     -n cloudkit-system
   ```

2. **Configure Operator:**
   ```yaml
   # config/manager/manager.yaml
   env:
     - name: CLOUDKIT_PROVISIONING_PROVIDER
       value: "aap"
     - name: CLOUDKIT_AAP_URL
       value: "https://aap.example.com/api/controller"
     - name: CLOUDKIT_AAP_TOKEN
       valueFrom:
         secretKeyRef:
           name: aap-credentials
           key: token
     - name: CLOUDKIT_AAP_PROVISION_TEMPLATE
       value: "innabox-create-compute-instance"
     - name: CLOUDKIT_AAP_DEPROVISION_TEMPLATE
       value: "innabox-delete-compute-instance"
     - name: CLOUDKIT_AAP_STATUS_POLL_INTERVAL
       value: "30s"
   ```

3. **Deploy Operator:**
   ```bash
   kubectl apply -f config/manager/manager.yaml
   ```

**Verification:**

```bash
# Check AAP connectivity from operator pod
AAP_URL="https://aap.example.com/api/v2"
AAP_TOKEN="your-token"

kubectl run -it --rm test-aap --image=curlimages/curl --restart=Never -- \
  curl -H "Authorization: Bearer $AAP_TOKEN" \
  $AAP_URL/ping/

# Verify templates exist in AAP
curl -H "Authorization: Bearer $AAP_TOKEN" \
  "$AAP_URL/job_templates/" | jq '.results[] | {name, id}'

curl -H "Authorization: Bearer $AAP_TOKEN" \
  "$AAP_URL/workflow_job_templates/" | jq '.results[] | {name, id}'

# Create test ComputeInstance
cat <<EOF | kubectl apply -f -
apiVersion: cloudkit.openshift.io/v1alpha1
kind: ComputeInstance
metadata:
  name: test-ci-aap
  namespace: default
spec:
  name: test-vm-aap
  vcpu: 2
  memory: 4096
  disk: 40
EOF

# Watch job status in CR
kubectl get computeinstance test-ci-aap -o jsonpath='{.status.provisionJob}' | jq

# Alternatively, use watch
watch -n 5 'kubectl get computeinstance test-ci-aap -o jsonpath="{.status.provisionJob}" | jq'

# Check AAP job directly
AAP_JOB_ID=$(kubectl get computeinstance test-ci-aap -o jsonpath='{.status.provisionJob.id}')
curl -H "Authorization: Bearer $AAP_TOKEN" \
  "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.status, .failed, .finished'

# Check operator logs for AAP API calls
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager -f | grep "AAP"
```

### 5.3 Migration from EDA to AAP Direct

Migrating from EDA to AAP Direct provides better feedback and error visibility.

**When to Migrate:**
- Need real-time job status visibility
- Want to prevent orphaned cloud resources on failures
- Require job cancellation capability during deletion
- Need crash recovery guarantees (job ID persistence)
- Want full error tracebacks from failed jobs

**Migration Prerequisites:**
1. AAP templates must accept resources in EDA event format (for compatibility)
2. Update AAP playbooks to NOT manage finalizers (operator will handle)
3. AAP Controller must be accessible from operator pods
4. AAP OAuth2 token created with necessary permissions

**Migration Steps:**

1. **Prepare AAP Playbooks:**

   Remove finalizer management from playbooks:
   ```yaml
   # OLD (EDA Provider - playbook manages finalizers):
   - name: Add finalizer to ComputeInstance
     kubernetes.core.k8s:
       state: patched
       kind: ComputeInstance
       name: "{{ ansible_eda.event.payload.metadata.name }}"
       namespace: "{{ ansible_eda.event.payload.metadata.namespace }}"
       definition:
         metadata:
           finalizers:
             - cloudkit.openshift.io/compute-instance-finalizer

   # NEW (AAP Direct - operator manages finalizers):
   # Remove the above task entirely
   ```

2. **Create AAP Token Secret:**
   ```bash
   kubectl create secret generic aap-credentials \
     --from-literal=token="YOUR_AAP_TOKEN" \
     -n cloudkit-system
   ```

3. **Update Operator Deployment:**
   ```bash
   # Edit operator deployment
   kubectl edit deployment cloudkit-operator-controller-manager -n cloudkit-system

   # Change environment variables:
   # - CLOUDKIT_PROVISIONING_PROVIDER: "aap"
   # - Add CLOUDKIT_AAP_* variables
   # - Remove CLOUDKIT_COMPUTE_INSTANCE_*_WEBHOOK variables
   ```

4. **Restart Operator:**
   ```bash
   kubectl rollout restart deployment/cloudkit-operator-controller-manager -n cloudkit-system
   ```

5. **Verify with Test ComputeInstance:**
   ```bash
   # Create test resource
   kubectl apply -f test-compute-instance.yaml

   # Verify job ID in status
   kubectl get computeinstance test-ci -o jsonpath='{.status.provisionJob.id}'
   # Should show AAP job ID (e.g., "4870"), not "eda-webhook"

   # Watch job progress
   kubectl get computeinstance test-ci -o jsonpath='{.status.provisionJob}' | jq
   ```

6. **Monitor Existing ComputeInstances:**

   ComputeInstances in steady state (Ready) will not be affected. ComputeInstances currently provisioning/deprovisioning may require manual intervention:

   ```bash
   # List ComputeInstances in non-Ready state
   kubectl get computeinstance -A --field-selector status.phase!=Ready

   # Check their provision job status
   kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob}'
   ```

**Rollback:**

If issues occur, rollback to EDA provider:

```bash
# Edit deployment
kubectl edit deployment cloudkit-operator-controller-manager -n cloudkit-system

# Change:
# - CLOUDKIT_PROVISIONING_PROVIDER: "eda"
# - Restore CLOUDKIT_COMPUTE_INSTANCE_*_WEBHOOK variables
# - Remove CLOUDKIT_AAP_* variables

# Restart operator
kubectl rollout restart deployment/cloudkit-operator-controller-manager -n cloudkit-system
```

**Post-Migration:**
- Update playbooks to remove annotation-based signaling if desired
- Monitor AAP API load (polling can increase API calls)
- Adjust `CLOUDKIT_AAP_STATUS_POLL_INTERVAL` if needed (30s-60s recommended)

### 5.4 Monitoring and Observability

#### ComputeInstance Status Fields

Both providers populate the `status` section of ComputeInstance CRs with job information.

**Status Structure:**

```yaml
status:
  phase: Progressing | Ready | Failed | Deleting

  provisionJob:
    id: "4870"  # AAP job ID or "eda-webhook"
    state: Running | Succeeded | Failed | Canceled | Unknown
    message: "Job running"
    blockDeletionOnFailure: true  # AAP: true, EDA: false

  deprovisionJob:
    id: "4925"
    state: Running
    message: "Deprovision job triggered"
    blockDeletionOnFailure: true

  # Other fields...
  conditions: [...]
```

**Querying Status:**

```bash
# Get full status
kubectl get computeinstance <name> -o yaml

# Get provision job status
kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob}' | jq

# Get job state only
kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob.state}'

# Get deprovision job status
kubectl get computeinstance <name> -o jsonpath='{.status.deprovisionJob}' | jq
```

#### Key Log Messages (AAP Direct)

The AAP Direct Provider logs detailed messages about job lifecycle:

**Provision Flow:**
```
"triggering provisioning"                      # TriggerProvision() called
"provision job triggered"                      # AAP job created successfully
"provision job still running"                  # Polling non-terminal job
"provision job succeeded"                      # Job reached Succeeded state
"provision job failed: [error details]"        # Job failed with error
```

**Deprovision Flow:**
```
"checking provision job before deprovision"              # isReadyForDeprovision() check
"provision job is running, attempting to cancel"         # Cancellation triggered
"canceled provision job"                                 # Cancellation successful
"provision job already terminal"                         # Job already complete
"deprovisioning not ready, requeueing"                   # Waiting for cancellation
"deprovision job triggered"                              # Deprovision started
"deprovision job succeeded"                              # Cleanup complete
"deprovision job failed: [error details]"                # Cleanup failed
```

**Viewing Logs:**

```bash
# Follow operator logs
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager -f

# Filter for specific ComputeInstance
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep "test-ci"

# Filter for provision events
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep "provision"

# Filter for AAP API calls
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep "AAP"
```

#### Prometheus Metrics (Future)

Future enhancements may include Prometheus metrics for:
- Job trigger counts (success/failure)
- Job duration histograms
- Job state distribution
- API call latencies
- Polling intervals

## 6. Testing Guidance

### 6.1 Manual Testing Scenarios

#### Scenario 1: Successful Provision and Deprovision (AAP Direct)

This scenario tests the happy path for resource lifecycle.

**Steps:**

```bash
# 1. Create ComputeInstance
cat <<EOF | kubectl apply -f -
apiVersion: cloudkit.openshift.io/v1alpha1
kind: ComputeInstance
metadata:
  name: test-ci-success
  namespace: default
spec:
  name: test-vm-success
  vcpu: 2
  memory: 4096
  disk: 40
EOF

# 2. Monitor provision job status
watch -n 5 'kubectl get computeinstance test-ci-success -o jsonpath="{.status.provisionJob}" | jq'

# 3. Verify state transitions: Pending → Running → Succeeded
# Expected states over time:
#   {id: "4870", state: "Pending", message: "Job queued"}
#   {id: "4870", state: "Running", message: "Job running"}
#   {id: "4870", state: "Succeeded", message: "Job completed successfully"}

# 4. Verify CR phase: Progressing → Ready
kubectl get computeinstance test-ci-success -o jsonpath='{.status.phase}'
# Expected: Ready

# 5. Delete ComputeInstance
kubectl delete computeinstance test-ci-success

# 6. Monitor deprovision job
watch -n 5 'kubectl get computeinstance test-ci-success -o jsonpath="{.status.deprovisionJob}" | jq'

# 7. Verify deprovision state transitions: Pending → Running → Succeeded
# Expected:
#   {id: "4925", state: "Running", message: "Deprovision job triggered"}
#   {id: "4925", state: "Succeeded", message: "Deprovision completed"}

# 8. Verify cleanup and CR deletion
kubectl get computeinstance test-ci-success
# Expected: NotFound
```

**Expected Behavior:**
- Provision job completes successfully
- CR moves to Ready phase
- Deprovision job completes successfully
- CR is deleted cleanly

#### Scenario 2: Deletion During Provisioning (AAP Direct)

This scenario tests the job cancellation flow when a resource is deleted while provisioning is still in progress.

**Steps:**

```bash
# 1. Create ComputeInstance
kubectl apply -f - <<EOF
apiVersion: cloudkit.openshift.io/v1alpha1
kind: ComputeInstance
metadata:
  name: test-ci-cancel
  namespace: default
spec:
  name: test-vm-cancel
  vcpu: 2
  memory: 4096
  disk: 40
EOF

# 2. Immediately delete (within 30 seconds, before job completes)
kubectl delete computeinstance test-ci-cancel &

# 3. Observe provision job cancellation
kubectl get computeinstance test-ci-cancel -o jsonpath='{.status.provisionJob.state}'
# Expected progression:
#   Running → Canceled

# 4. Observe deprovision triggered after cancellation
kubectl get computeinstance test-ci-cancel -o jsonpath='{.status.deprovisionJob.id}'
# Expected: AAP job ID (e.g., "4926")

# 5. Check operator logs for cancellation
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep "cancel"
# Expected: "provision job is running, attempting to cancel"
#           "canceled provision job"

# 6. Verify final cleanup
kubectl get computeinstance test-ci-cancel
# Expected: NotFound (after deprovision completes)
```

**Expected Behavior:**
- Provision job is canceled when deletion is requested
- Operator waits for cancellation to complete
- Deprovision job is triggered after provision job reaches Canceled state
- CR is deleted cleanly

#### Scenario 3: Failed Provision Job (AAP Direct)

This scenario tests error handling when a provision job fails.

**Steps:**

```bash
# 1. Create ComputeInstance with invalid configuration
# (e.g., invalid disk size, unavailable resources, network issues)
kubectl apply -f - <<EOF
apiVersion: cloudkit.openshift.io/v1alpha1
kind: ComputeInstance
metadata:
  name: test-ci-fail
  namespace: default
spec:
  name: test-vm-fail
  vcpu: 999  # Invalid: exceeds quota
  memory: 999999
  disk: 40
EOF

# 2. Observe job failure
kubectl get computeinstance test-ci-fail -o jsonpath='{.status.provisionJob}' | jq
# Expected:
# {
#   "id": "4871",
#   "state": "Failed",
#   "message": "AAP job failed: [error details from playbook]",
#   "blockDeletionOnFailure": true
# }

# 3. Check CR phase
kubectl get computeinstance test-ci-fail -o jsonpath='{.status.phase}'
# Expected: Failed

# 4. Review error details in AAP UI or via API
AAP_JOB_ID=$(kubectl get computeinstance test-ci-fail -o jsonpath='{.status.provisionJob.id}')
curl -H "Authorization: Bearer $AAP_TOKEN" \
  "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.result_traceback'

# 5. Attempt deletion
kubectl delete computeinstance test-ci-fail

# 6. Verify deprovision is triggered (cleanup attempt)
kubectl get computeinstance test-ci-fail -o jsonpath='{.status.deprovisionJob}' | jq
```

**Expected Behavior:**
- Provision job fails with error message
- CR moves to Failed phase
- Error details are visible in status
- Deprovision job is still triggered on deletion (cleanup attempt)

#### Scenario 4: EDA Provider (Backward Compatibility)

This scenario verifies the EDA provider still works as expected.

**Steps:**

```bash
# 1. Ensure operator is configured for EDA provider
kubectl get deployment cloudkit-operator-controller-manager -n cloudkit-system \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CLOUDKIT_PROVISIONING_PROVIDER")].value}'
# Expected: "eda"

# 2. Create ComputeInstance
kubectl apply -f - <<EOF
apiVersion: cloudkit.openshift.io/v1alpha1
kind: ComputeInstance
metadata:
  name: test-ci-eda
  namespace: default
spec:
  name: test-vm-eda
  vcpu: 2
  memory: 4096
  disk: 40
EOF

# 3. Check job ID
kubectl get computeinstance test-ci-eda -o jsonpath='{.status.provisionJob.id}'
# Expected: "eda-webhook"

# 4. Check job state
kubectl get computeinstance test-ci-eda -o jsonpath='{.status.provisionJob.state}'
# Expected: "Unknown"

# 5. Wait for AAP to update annotation
kubectl get computeinstance test-ci-eda -o jsonpath='{.metadata.annotations.cloudkit\.openshift\.io/reconciled-config-version}'
# Should match desired-config-version after provision completes

# 6. Verify CR becomes Ready
kubectl get computeinstance test-ci-eda -o jsonpath='{.status.phase}'
# Expected: Ready
```

**Expected Behavior:**
- Job ID is "eda-webhook"
- Job state is "Unknown"
- CR becomes Ready when annotation is updated by AAP
- Finalizer is managed by AAP playbook

### 6.2 Unit Testing

Unit tests validate individual components in isolation.

**Test Files:**
- `cloudkit-operator/internal/provisioning/provider_test.go` - Interface contract tests
- `cloudkit-operator/internal/provisioning/eda_provider_test.go` - EDA provider tests
- `cloudkit-operator/internal/provisioning/aap_provider_test.go` - AAP provider tests
- `cloudkit-operator/internal/aap/client_test.go` - AAP client tests

**Running Unit Tests:**

```bash
cd /path/to/cloudkit-operator

# Run all tests
make test

# Run specific package tests
go test ./internal/provisioning/... -v

# Run tests with coverage
go test ./internal/provisioning/... -cover -coverprofile=coverage.out

# View coverage report
go tool cover -html=coverage.out
```

**Key Test Coverage:**
- Provider interface contract (all methods)
- Job state transitions (Pending → Running → Succeeded/Failed)
- Idempotency (multiple triggers with same job ID)
- Job cancellation logic
- Template auto-detection
- Error handling (network failures, 404s, 401s, 500s)

### 6.3 Integration Testing

Integration tests validate end-to-end workflows with fake Kubernetes clients and mock AAP clients.

**Test Files:**
- `cloudkit-operator/internal/controller/computeinstance_integration_test.go`

**Running Integration Tests:**

```bash
cd /path/to/cloudkit-operator

# Run integration tests
go test ./internal/controller/... -v -tags=integration

# Run specific test
go test ./internal/controller/... -v -run TestComputeInstanceController_DeletionDuringProvisioning
```

**Test Scenarios Covered:**
- Successful provision → deprovision flow
- Deletion during provisioning (job cancellation)
- Failed provision job handling
- Failed deprovision job with BlockDeletionOnFailure
- Terminal state detection
- Duplicate job prevention
- Crash recovery (job ID persistence)

Integration tests use fake Kubernetes clients and mock AAP clients to verify end-to-end workflows without requiring actual AAP infrastructure.

## 7. Troubleshooting

### 7.1 Common Issues

#### EDA Provider Issues

| Issue | Symptoms | Root Cause | Solution |
|-------|----------|------------|----------|
| Webhook not triggered | Provision job ID never appears in status | EDA service unreachable, network issues | Check EDA service logs: `kubectl logs -n cloudkit-system deployment/eda-service`. Verify webhook URL is correct. Test connectivity from operator pod. |
| AAP finalizer not set | CR stuck in Deleting, finalizer never removed | AAP playbook not adding finalizer on successful provision | Update AAP playbook to add `cloudkit.openshift.io/compute-instance-finalizer` to `metadata.finalizers`. |
| Annotation not updated | CR stays in Progressing forever | AAP playbook not setting `reconciled-config-version` annotation | Update AAP playbook to set `cloudkit.openshift.io/reconciled-config-version` annotation to match desired version. |
| EDA 500 error | Webhook call returns 500 | EDA rulebook error, AAP template misconfiguration | Check EDA logs for rulebook errors. Verify AAP job template exists and is accessible. |

#### AAP Direct Provider Issues

| Issue | Symptoms | Root Cause | Solution |
|-------|----------|------------|----------|
| Authentication failure | Error: "401 Unauthorized" | Invalid or expired AAP token | Verify AAP token in secret: `kubectl get secret aap-credentials -o jsonpath='{.data.token}' \| base64 -d`. Test token with curl: `curl -H "Authorization: Bearer $TOKEN" $AAP_URL/ping/`. Regenerate token if expired. |
| Job not found | Error: "404 Not Found" when polling job | AAP purges old jobs based on retention policy | AAP automatically purges completed jobs after retention period. Operator treats 404 as terminal state and proceeds. Adjust AAP job retention if needed. |
| Template not found | Error: "Template 'foo' not found" | Template name mismatch or template doesn't exist | List templates: `curl -H "Authorization: Bearer $TOKEN" $AAP_URL/job_templates/`. Verify `CLOUDKIT_AAP_PROVISION_TEMPLATE` matches AAP template name exactly (case-sensitive). |
| Cancellation not allowed | Error: "405 Method Not Allowed" when canceling | Job already in terminal state | Job reached terminal state between check and cancel. Operator proceeds with deprovision. This is normal and not an error. |
| SSL certificate error | Error: "x509: certificate signed by unknown authority" | AAP uses self-signed certificate or custom CA | Add CA certificate to operator deployment. Mount CA cert as volume and set `SSL_CERT_FILE` environment variable. Or disable SSL verification (not recommended for production). |
| Poll interval too aggressive | AAP API rate limiting errors | Poll interval set too low | Increase `CLOUDKIT_AAP_STATUS_POLL_INTERVAL` to 30s or 60s. Monitor AAP API load. |

### 7.2 Debugging Commands

#### General Debugging

```bash
# View full ComputeInstance status
kubectl get computeinstance <name> -o yaml

# Check provision job status
kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob}' | jq

# Check deprovision job status
kubectl get computeinstance <name> -o jsonpath='{.status.deprovisionJob}' | jq

# Check CR phase
kubectl get computeinstance <name> -o jsonpath='{.status.phase}'

# Check finalizers
kubectl get computeinstance <name> -o jsonpath='{.metadata.finalizers}'

# Check annotations
kubectl get computeinstance <name> -o jsonpath='{.metadata.annotations}' | jq
```

#### Controller Logs

```bash
# Follow controller logs
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager -f

# Filter logs for specific ComputeInstance
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep "test-ci"

# Filter for errors
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep -i error

# Filter for provision events
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager | grep provision

# Get recent logs (last 100 lines)
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager --tail=100
```

#### AAP API Debugging

```bash
# Set variables
AAP_URL="https://aap.example.com/api/v2"
AAP_TOKEN="your-token-here"

# Test connectivity
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/ping/"

# List job templates
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/job_templates/" | jq '.results[] | {name, id}'

# List workflow templates
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/workflow_job_templates/" | jq '.results[] | {name, id}'

# Query specific job
AAP_JOB_ID=$(kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob.id}')
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/" | jq

# Check job status only
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.status, .failed, .finished'

# Get job error details
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.result_traceback'

# Check if job can be canceled
curl -X POST -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/cancel/"
# Response codes:
# 202 = cancellation initiated
# 405 = job already terminal (cannot cancel)
# 404 = job not found

# List recent jobs
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/?order_by=-id&page_size=10" | jq '.results[] | {id, name, status, finished}'
```

#### Network Debugging

```bash
# Test AAP connectivity from operator pod
kubectl exec -it -n cloudkit-system deployment/cloudkit-operator-controller-manager -- sh

# Inside pod:
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/ping/"

# Test DNS resolution
nslookup aap.example.com

# Test TLS handshake
openssl s_client -connect aap.example.com:443 -servername aap.example.com

# Exit pod
exit
```

### 7.3 Recovery Procedures

#### Stuck ComputeInstance in Progressing

**Symptoms:**
- CR stuck in Progressing phase
- Provision job shows Running state for extended period
- No updates to CR status

**Diagnosis:**

```bash
# Check provision job state
kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob}' | jq

# If job ID exists, check AAP directly
AAP_JOB_ID=$(kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob.id}')
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.status'
```

**Recovery:**

```bash
# If AAP job succeeded but CR not updated:
# 1. Check if VM/resources were actually created
# 2. Manually update CR status if needed
# 3. Or delete and recreate

# If AAP job failed:
# 1. Check error details in AAP
AAP_JOB_ID=$(kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob.id}')
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.result_traceback'

# 2. Fix underlying issue (quota, network, etc.)
# 3. Delete and recreate ComputeInstance

# If safe to force delete (no cloud resources created):
kubectl patch computeinstance <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete computeinstance <name>
```

#### Failed Deprovision Job (BlockDeletionOnFailure=true)

**Symptoms:**
- CR stuck in Deleting phase
- Deprovision job shows Failed state
- Finalizer prevents CR deletion

**Diagnosis:**

```bash
# Check deprovision job status
kubectl get computeinstance <name> -o jsonpath='{.status.deprovisionJob}' | jq

# Check AAP job for error details
AAP_JOB_ID=$(kubectl get computeinstance <name> -o jsonpath='{.status.deprovisionJob.id}')
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.result_traceback'
```

**Recovery:**

```bash
# 1. Manually clean up cloud resources
# - Log in to infrastructure provider (OpenShift Virtualization, VMware, etc.)
# - Verify VM/resources exist
# - Manually delete VM, networks, storage, etc.

# 2. Remove finalizers to allow CR deletion
kubectl patch computeinstance <name> -p '{"metadata":{"finalizers":[]}}' --type=merge

# 3. Delete CR
kubectl delete computeinstance <name>

# Verify deletion
kubectl get computeinstance <name>
# Expected: NotFound
```

**Prevention:**
- Ensure deprovision playbooks have proper error handling
- Test deprovision playbooks in non-production environments
- Monitor deprovision job failures and fix underlying issues

#### Duplicate Job Triggers

**Symptoms:**
- Multiple AAP jobs triggered for same ComputeInstance
- Different job IDs in CR status on each reconciliation

**Diagnosis:**

```bash
# Check CR status history
kubectl get computeinstance <name> -o yaml | grep -A 10 provisionJob

# List AAP jobs for this resource
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/?name__contains=<name>" | jq '.results[] | {id, status, created}'
```

**Root Cause:**
- Status update failed after job trigger (conflict, timeout)
- Job ID not persisted before controller restart

**Recovery:**

```bash
# 1. Identify the correct/latest job
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/?name__contains=<name>&order_by=-id" | jq '.results[0]'

# 2. Cancel duplicate jobs if needed
for job_id in <duplicate-job-ids>; do
  curl -X POST -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$job_id/cancel/"
done

# 3. Update CR status with correct job ID
kubectl edit computeinstance <name>
# Manually update status.provisionJob.id to correct value
```

**Prevention:**
- Operator already uses `retry.RetryOnConflict` for status updates
- Ensure sufficient controller resources (CPU, memory) to avoid timeouts
- Increase API server timeout if needed

#### Controller Crash During Job Execution

**Symptoms:**
- Controller pod restarted during provisioning
- Job ID exists in CR status
- Uncertain if job completed

**Diagnosis:**

```bash
# Check job ID in CR status
AAP_JOB_ID=$(kubectl get computeinstance <name> -o jsonpath='{.status.provisionJob.id}')

# Check job status in AAP
curl -H "Authorization: Bearer $AAP_TOKEN" "$AAP_URL/jobs/$AAP_JOB_ID/" | jq '.status'
```

**Recovery:**

AAP Direct Provider is designed for crash recovery:

```bash
# 1. Controller will automatically resume on next reconciliation
# 2. Job ID is persisted in CR status
# 3. Controller will poll job status from AAP
# 4. No manual intervention needed

# Verify recovery:
kubectl logs -n cloudkit-system deployment/cloudkit-operator-controller-manager -f | grep <name>
# Should show: "checking provision job status" and resume from there
```

**Expected Behavior:**
- Controller resumes polling job status
- No duplicate jobs are triggered
- Job completion is detected and CR status updated

## 8. Design Decisions

### 8.1 Why Provider Abstraction?

The provider abstraction layer was introduced to support multiple provisioning backends without changing controller logic.

**Key Benefits:**

1. **Flexibility:** Support different operational models (EDA vs direct API) in the same codebase
2. **Evolution:** Migrate from EDA to AAP Direct without breaking existing deployments
3. **Testing:** Mock providers enable unit and integration tests without real AAP
4. **Future-Proof:** Extensible to other backends (Terraform Cloud, Pulumi, native cloud APIs)
5. **Separation of Concerns:** Controller logic focuses on CR lifecycle, providers handle automation details

### 8.2 Why Active Polling vs Passive Annotation?

The AAP Direct Provider uses active polling (operator queries AAP API) instead of passive annotation updates (AAP updates CR).

**Benefits of Active Polling:**

1. **Status Visibility:** Real-time job state (Pending, Running, etc.), not just "triggered" or "done"
2. **Error Details:** Full AAP traceback and error messages immediately available
3. **Progress Updates:** Can implement progress percentage in future (AAP provides this data)
4. **Cancellation:** Ability to cancel running jobs during deletion
5. **Decoupling:** AAP playbooks don't need Kubernetes API access or CR update logic
6. **Reliability:** Operator drives status checks, not dependent on AAP successfully updating CR

**Trade-offs:**

- Increased API calls to AAP (mitigated by configurable poll interval)
- Slightly higher latency for status updates (mitigated by reasonable poll intervals like 30s)

### 8.3 Why Block Deletion on Failed Deprovision?

The AAP Direct Provider sets `BlockDeletionOnFailure=true` for deprovision jobs, preventing CR deletion if cleanup fails.

**Rationale:**

1. **Orphaned Resources:** Failed deprovision likely means VM, networks, storage still exist
2. **Cost Control:** Prevent cloud resource leaks (VMs incur costs)
3. **Explicit Recovery:** Force operator intervention to verify cleanup before CR deletion
4. **Safety First:** Better to block deletion than risk orphaning expensive infrastructure

**Example Scenario:**

```
1. User deletes ComputeInstance
2. Deprovision job triggers
3. AAP playbook fails (network timeout, API error, quota issue)
4. VM still exists in infrastructure
5. Without BlockDeletionOnFailure:
   - CR would be deleted
   - VM remains orphaned
   - No record of VM in Kubernetes
   - Manual cleanup required by infrastructure admin
6. With BlockDeletionOnFailure:
   - CR remains in Deleting phase
   - Operator can see failed job and error message
   - Admin investigates and manually cleans up VM
   - Admin removes finalizer to delete CR
   - Clear audit trail
```

**EDA Provider Behavior:**

EDA Provider sets `BlockDeletionOnFailure=false` because:
- EDA approach has no visibility into job failures
- AAP playbook manages finalizer removal
- Blocking would prevent CR deletion even on success (no status feedback)

### 8.4 Why Separate ProvisionJob and DeprovisionJob Status?

The CR status tracks provision and deprovision jobs separately instead of a single "currentJob" field.

**Benefits:**

1. **Crash Recovery:** Both statuses persist in CR, controller can resume after restart
2. **Historical Context:** Can see provision job details even during deprovision
3. **Different Policies:** AAP blocks on deprovision failure, EDA doesn't
4. **State Clarity:** Explicit lifecycle phases (provisioning vs deprovisioning)
5. **Debugging:** Full job history visible in CR status for troubleshooting

**Example:**

```yaml
status:
  provisionJob:
    id: "4870"
    state: Succeeded
    message: "Provision completed successfully"
  deprovisionJob:
    id: "4925"
    state: Running
    message: "Deprovisioning in progress"
```

From this status, operator can determine:
- Provision succeeded (resources were created)
- Deprovision is currently running
- If deprovision fails, can reference provision job for context

## 9. Future Enhancements

The provisioning abstraction enables several future improvements:

### 9.1 Additional Provider Implementations

**Terraform Cloud Provider:**
- Direct integration with Terraform Cloud/Enterprise API
- Workspace-based provisioning
- State management in Terraform backend
- Plan/apply workflow for safety

**Pulumi Provider:**
- Pulumi Automation API integration
- Multiple language support (Go, Python, TypeScript)
- Stack-based resource management

**Native Cloud Provider APIs:**
- Direct AWS EC2, Azure Compute, GCP Compute Engine APIs
- Eliminate AAP dependency for simple VM provisioning
- Faster execution (no Ansible overhead)

### 9.2 Enhanced Progress Reporting

AAP API provides progress information that could be surfaced in CR status:

```yaml
status:
  provisionJob:
    id: "4870"
    state: Running
    progress: 65  # Percentage complete (0-100)
    currentStage: "Configuring network interfaces"
```

**Implementation:**
- Parse AAP job events API (`/api/v2/jobs/{id}/job_events/`)
- Extract playbook task progress
- Update CR status with progress percentage

### 9.3 Webhook Notifications

Send webhook notifications when jobs complete:

```yaml
spec:
  webhooks:
    onProvisionComplete: "https://notification-service/provision-complete"
    onDeprovisionComplete: "https://notification-service/deprovision-complete"
```

**Use Cases:**
- Integrate with external systems (ITSM, monitoring)
- Trigger downstream workflows
- Send alerts on failures

### 9.4 Job Event Streaming

Real-time streaming of job events instead of polling:

**AAP Server-Sent Events (SSE):**
- AAP supports SSE for job events
- Operator could subscribe to job event stream
- Eliminates polling overhead and provides instant updates
- Would require persistent connection management and reconnection logic

### 9.5 Multi-Cloud Provider Support

Support multiple cloud providers in parallel:

```yaml
spec:
  cloudProvider: aws | azure | gcp | vmware | openshift-virt
  providerConfig:
    aws:
      region: us-east-1
      instanceType: t3.medium
    azure:
      location: eastus
      vmSize: Standard_B2s
```

The provider interface could be extended with cloud-specific methods for metadata retrieval and configuration validation while maintaining the core provisioning capabilities.

### 9.6 Automated Rollback on Failed Provision

Automatically clean up partially created resources if provision fails:

```yaml
spec:
  rollbackPolicy: automatic | manual
```

**Implementation:**
- Trigger deprovision job immediately on provision failure
- Clean up any partially created resources
- Mark CR as Failed after rollback completes

### 9.7 Dry-Run Mode

Support dry-run for provision operations:

```yaml
spec:
  dryRun: true
```

**Behavior:**
- AAP runs playbook with `--check` flag
- No actual infrastructure changes
- Reports what would be created/changed
- Useful for validation and testing

## 10. References

### Documentation

- [Enhancement Proposal: AAP Integration Abstraction](https://github.com/osac-project/enhancement-proposals/tree/main/enhancements/aap-provisioning-abstraction) - Original design document
- [Main OSAC Architecture](../README.md) - Overall OSAC architecture overview
- [Cluster Fulfillment Architecture](../cluster-fulfillment.md) - Cluster provisioning workflows
- [VM Fulfillment Architecture](../vm-fulfillment.md) - Virtual machine provisioning workflows

### Code Repositories

- [cloudkit-operator Repository](https://github.com/innabox/cloudkit-operator) - Controller implementation (soon to be osac-operator)
- [osac-docs Repository](https://github.com/osac-project/osac-docs) - OSAC documentation
- [enhancement-proposals Repository](https://github.com/osac-project/enhancement-proposals) - Enhancement proposals and design documents

### Source Files

**Provider Abstraction:**
- `cloudkit-operator/internal/provisioning/provider.go` - Interface definitions
- `cloudkit-operator/internal/provisioning/eda_provider.go` - EDA implementation
- `cloudkit-operator/internal/provisioning/aap_provider.go` - AAP Direct implementation

**AAP Integration:**
- `cloudkit-operator/internal/aap/client.go` - AAP REST API client
- `cloudkit-operator/internal/aap/types.go` - AAP request/response types

**Controller:**
- `cloudkit-operator/internal/controller/computeinstance_controller.go` - ComputeInstance reconciliation logic

**Tests:**
- `cloudkit-operator/internal/provisioning/*_test.go` - Provider unit tests
- `cloudkit-operator/internal/controller/computeinstance_integration_test.go` - Integration tests

### External Documentation

- [AAP API Documentation](https://docs.ansible.com/automation-controller/latest/html/controllerapi/index.html) - Ansible Automation Platform REST API reference
- [AAP Job Launch API](https://docs.ansible.com/automation-controller/latest/html/controllerapi/api_ref.html#/Jobs) - Job template launch endpoints
- [AAP Authentication](https://docs.ansible.com/automation-controller/latest/html/userguide/applications_auth.html) - OAuth2 token creation and management
- [Event-Driven Ansible](https://www.ansible.com/products/event-driven-ansible) - EDA overview and concepts

### Related Projects

- [Kubernetes Controller Runtime](https://github.com/kubernetes-sigs/controller-runtime) - Framework used for cloudkit-operator
- [OpenShift Virtualization](https://docs.openshift.com/container-platform/latest/virt/about-virt.html) - VM infrastructure provider

---

**Note:** This documentation describes the cloudkit-operator implementation. The operator will be renamed to osac-operator as part of the OSAC project consolidation. Configuration environment variables and API group names will be updated accordingly in a future release.
