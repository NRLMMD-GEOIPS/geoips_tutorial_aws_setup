# Startup Scripts for GeoIPS Tutorials on AWS
This repo contains startup scripts for running GeoIPS tutorials on AWS using JupyterHub.

# System requirements
To run the GeoIPS tutorials, the instance used must have:
- Rocky Linux 9 (other Red Hat variants would probably work)
- 1 CPU per user
- At least 40GB RAM per user
- At least 10GB storage per user

# Networking
I purchased geoips-tutorial.org and have created certs for it. When creating a
new instance, you will always be given a new IP address. To make the networking
work, you'll need to replace the IP in the CloudFlare DNS settings.

The certificate is stored in AWS Secret Manager, but is not currently configured
to automatically rotate. That might be worth setting up in the future via a
lambda function.

# Using these scripts
There are two scripts that must be run to get JupyterHub started. They should be
run in order. I am fairly confident that they can be run multiple times without
side effects, but if you encounter anything weird, restart your instance and
reinstall from scratch.
```
# Set up the root environment and user environments for the specified number of users.
> ./setup.sh
# Configure and execute JupyterHub.
> ./start_jupyterhub.sh
```

These scripts should be called in the `User Data` section of the EC2 instance
launch setup.

# Testing
The same startup method can be used in a Docker container for testing purposes.
The scripts rely on `dnf` for package install so they must be run on a Red Hat
variant. So far, they have only been tested on Rocky Linux 9.

# Updating the certificate
To update the certificate:
- launch a tiny EC2 instance
- register its IP with the CloudFlare DNS
- ssh to the EC2 instance
- install certbot and use it to getnerate the cert
- update the GEOIPS_TUTORIAL_SSL secret in AWS Secret Manager
    - The format of the value should be:
      {
        "cert": cert contents with newlines
        "key": key with newlines
      }

