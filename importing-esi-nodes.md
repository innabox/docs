# Importing ESI nodes into ACM (the hard way)

This document describes the steps necessary to import an ESI node into ACM. We assume that you have an ESI project and have been assigned (or have acquired) some nodes.

## Configure networking

If you're just getting started, you will first need to create the network infrastructure for your nodes.

### Create a router

A *router* provides your baremetal nodes with access to the outside world.

1. Create a router:

    ```
    openstack router create myrouter
    ```

2. Attach the router to a public network:

    ```
    openstack router set myrouter --external-gateway external
    ```

### Create a network

When you create a network, you create a VLAN that will provide your nodes with an isolated layer 2 domain.

1. Create a network:

    ```
    openstack network create mynetwork
    ```

2. Create a subnet. A subnet defines a pool of addresses that can be assigned to nodes on the network. The `--subnet-range` option sets the CIDR for the network, while the `--allocation-pool` option restricts the range of automatically assigned addresses (which is useful if you will need to manually allocate some addresses for VIPs, etc):

    ```
    openstack subnet create mynetwork-subnet --network mynetwork \
      --subnet-range 10.10.10.0/24 \
      --allocation-pool start=10.10.10.10,end=10.10.10.254
    ```

### Attach the network to the router

1. Attach the subnet you just created to your router:

    ```
    openstack router add subnet mynetwork-subnet
    ```

## Register nodes with ACM

In order to register the nodes with ACM, we need to boot them using the discovery image provided by our target infrastructure environment. 

1. Get the URL for the discovery image:

    ```
    discovery_url=$(kubectl get infraenv myinfraenv -o jsonpath='{ .status.isoDownloadURL }')
    ```

2. Remove any existing network attachments from your nodes. This isn't necessary if you have just acquired the nodes; you only need to do this if the nodes were previously attached to a network:

    ```
    openstack esi node network detach --all mynode
    ```

3. Attach the node to the ESI provisioning network:

    ```
    openstack esi node network attach --network provisioning mynode
    ```

4. Configure the node to boot from the discovery image:

    ```
    openstack baremetal node set mynode \
      --instance-info deploy_interface=ramdisk \
      --instance-info boot_iso="$discovery_url"
    ```

5. Boot the node:

    ```
    openstack baremetal node deploy mynode
    ```

Wait for the nodes to boot and appear as agents in the infrastructure environment.

## Attach the nodes to your target subnet

Once the nodes have registered with the infrastructure environment, you need to move them off the provisioning network and onto the network we created earlier:

1. Detach the node from the provisioning network:

    ```
    openstack esi node network detach --all mynode
    ```

1. Attach the node your target network:

    ```
    openstack esi node network attach --network mynetwork mynode
    ```

1. The nodes are configured to boot from the discovery CD. We need to configure the node to boot from disk:

    ```
    openstack baremetal node boot device set mynode disk --persistent
    ```

You will see that the discovered IP addresses for the node are updated to reflect the new network attachment.

## Update agent metadata

When a node is registered as an agent in ACM, it is identified by a UUID. There is a display hostname associated with the agent; in the absence of reverse DNS, the hostname will be generated from the IP address of the node at the time it was registered. Since we have moved the node onto a different network from the one on which it was discovered, these hostnames have no obvious relation to the node. We would like the agent hostnames to reflect the ESI nodename of the associated node.

1. Get the MAC address of the agent:

    ```
    macaddr=$(kubectl get agent 11111111-1111-1111-1111-111111111111 \
      -o jsonpath='{.status.inventory.interfaces[?(@.flags[-1] == "running")].macAddress}')
    ```

1. Find the corresponding ESI node:

    ```
    node=$(openstack baremetal port list --address "$macaddr" -f value -c uuid |
      xargs openstack baremetal port show -f value -c node_uuid)
    ```

1. Write the node information to a temporary file:

    ```
    openstack baremetal node show "$node" -f json > node.json
    ```

1. Update the agent hostname using information from the ESI node:

    ```
    hostname=$(jq -r .name node.json)
    kubectl patch agent 11111111-1111-1111-1111-111111111111 --type json --patch-file /dev/stdin <<EOF
    [
    {"op": "add", "path": "/spec/hostname", "value": "${node,,}"}
    ]
    EOF
    ```

    (The expression `${node,,}` is a bash expression that will lower case the node name, which is necessary to meet kubernetes object naming requirements.)

1. Label the agent with the ESI resource class (this is an optional step, but could in theory be used for selecting specific agents from a pool):

    ```
    resource_class=$(jq -r .resource_class node.json)
    kubectl label 11111111-1111-1111-1111-111111111111 \
      esi.nerc.mghpcc.org/resource_class="$resource_class"
    ```

## Approve the agents

When a node is first registered as an agent it will be in a pending state. You need to approve it before it can be used for cluster deployment:

```
kubectl patch agent 11111111-1111-1111-1111-111111111111 --type json --patch-file /dev/stdin <<EOF
[{"op": "replace", "path": "/spec/approved", "value": true}]
EOF
```

## View the fruits of your labor

When you're done, the agent should be registered with ACM, approved, and have the expected hostname. For example:

```
$ kubectl get agent -o wide
NAME                                   CLUSTER   APPROVED   ROLE          STAGE   HOSTNAME              REQUESTED HOSTNAME
07e21dd7-5b00-2565-ffae-485f1bf3aabc             true       auto-assign           host-192-168-11-22    moc-r4pac24u35-s3a
```
