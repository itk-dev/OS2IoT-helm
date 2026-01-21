To install OS2IoT with this GitOps [template](https://github.com/os2iot/OS2IoT-helm), you need to have a
Kubernetes cluster with the following installed:

* Helm 3

This deployment documentation must be followed and executed in the exact order as described below. This is
due to some services depending on other services being ready before they can be installed.

In particular, `ArgoCD` needs to be installed before `Argo resources`, `sealed secrets` etc.

The application also requires generation of API keys, etc., and that you use sealed secrets to store them before a
given service can be installed. Some services also require keys/secrets from one service to communicate with another.

Also, because all configuration is stored in GitOps as code, you will need to update secrets and URLs to match your
domain and setup. This document will guide you through the process of setting up OS2IoT.

## Variables

Throughout this installation documentation, some values are used multiple times. These values are defined in the
following variables:

* `FQDN`: The fully qualified domain name of the cluster (e.g. aarhus.dk).
* `CERT_MAIL`: The email address used to request a certificate from Let's Encrypt.

They are used with this notation `<FQDN>` in the configuration snippets.

If you want to randomly generate keys and password, you can use this command:

```shell
echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)"
```

## Bootstrap continuous deployment

The first step is
to [create](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)
a new GitHub repository based on this [template repository](https://github.com/os2iot/OS2IoT-helm).

### ArgoCD

For continuous development and using GitOps to handle updates and configuration
changes, [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) needs to be bootstrapped into the cluster.

To do so, configure the domain in `applications/argo-cd/values.yaml`:

```yaml
global:
  domain: argo.<FQDN>
```

Then install ArgoCD using the following commands:

```shell
helm repo add argocd https://argoproj.github.io/argo-helm
helm repo update
cd applications/argo-cd
helm dependency build
kubectl create namespace argo-cd
helm template argo-cd . -n argo-cd | kubectl apply -f -
```

Because we are installing the ingress controller with ArgoCD, it is only accessable by using port forwarding at this
point in the installation:

```shell
kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443
```

You can ensure that ArgoCD is running by opening the ingress URL:

```shell
open http://127.0.0.1:8443
```

You can log into the web-based user interface with the username `admin` and get the password with this command:

```shell
kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Optionally, [Authentik](https://goauthentik.io/) can be installed as a single-sign-on (SSO) provider for
the internal services in the cluster. See the [Authentik](authentik.md) for more information.

### Argo resources (applications)

Now we can install the Argo resources that define the applications and their configuration. But first, we need to
change the repository URL to our own repository.

Edit `applications/argo-cd-resources/values.yaml`:

```yaml
repoUrl: https://github.com/os2iot/<YOUR REPO>.git
```

Edit `applications/cert-manager/templates/cluster-issuer.yaml` and change the email address to your own:

```yaml
spec:
  acme:
    email: <CERT_MAIL>
 ```

Now commit the changes to the repository before the next step in Argo installation, which is to install the resources:

```shell
cd applications/argo-cd-resources/
helm template argo-cd-resources . -n argo-cd | kubectl apply -f -
```

This will install all the applications from `applications/argo-cd-resources/values.yaml` that are set to
`automated: true` which are all the applications that do not need configuration changes.

All other applications will need to have their configuration updated and committed to the repository
before they can be installed.


-------------------

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  creationTimestamp: null
  name: cloudnative-pg-cluster-chirpstack
  namespace: chirpstack
stringData:
  username: chirpstack
  password: <PASSWORD>
```

kubeseal --format yaml  < applications/chirpstack/local-secrets/cloudnative-pg-cluster-secret.yaml   > applications/chirpstack/templates/cloudnative-pg-cluster-sealed-secret.yaml
