## Instructions

### Envoy Proxy Deployment
This deployment does the following things:
* It uses `envoyproxy/envoy:v1.34.7` as the container image.
* It mounts a directory `/global/cfs/cdirs/m2845/atlas-spin` at the CFS file system at NERSC to `/envoy-config` in the container.
* It runs `envoy -c /envoy-config/envoy_config.yaml` to start the Envoy proxy. The configuration file is copied [here](1.0-envoy-proxy/envoy_config.yaml) for reference.
* It listens on port `9097` for incoming TCP traffic.

The Triton Server address is hardcoded in the [envoy_esd.yaml](1.0-envoy-proxy/envoy_config.yaml) file. If a different Triton server is launched, please modify the address accordingly.


### Envoy Service
This service does the following things:
* It creates a _clusterIP_ type service that exposes the Envoy proxy deployment.
* It listens on port `9097` and forwards the traffic to the Envoy proxy deployment on the same port through a selector: `workload.user.cattle.io/workloadselector: apps.deployment-iaas-gnn4itk-envoy-proxy`, which can be found in the deployment yaml file above.

### Ingress and TLS
The ingress and SSL/TLS configuration is handled by `https://github.com/dingp/spin-acme`. Follow the **Case 2** instructions in the repository. An example of modified values can be found [here](3.0-ingress/values-local.yaml).

> [!NOTE]
> The IaaS does not have a web server running on port 80, which is required for the ACME HTTP-01 challenge.
> Therefore, the `spin-acme` creates a dummy web server deployment and service to handle the challenge so as to obtain the SSL/TLS certificates.

After you have successfully obtained the certificates, you can check the Secrets in the Storage section of the Rancher UI, named _tls-cert_. In the Data section, it should show something like "Domain Name iaasdemo.ml4phys.com
Expires: Mon, Dec 8 2025  8:26:51 pm"

You will have to modify the Ingress so that it points to the Envoy service. An example can be found [here](3.0-ingress/ingress.yaml).

> [!IMPORTANT]
> The Ingress assumes the Triton client uses the `gPRC` protocol. If your client uses HTTP/REST, you will have to update the Ingress.



