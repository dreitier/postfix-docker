# Postfix relay running in Kubernetes
This repository has an example of a postfix relay running in Kubernetes using a helm chart.

## Getting started
### Run locally with Docker
Run the postfix relay locally for testing
```bash
# Need to set SMTP connection details
export SMTP="[smtp.mailgun.org]:587"
export USERNAME=<your smtp username>
export PASSWORD=<your smtp password>

# Set list of allowed networks
export TX_SMTP_RELAY_NETWORKS='10.0.0.0/8,127.0.0.0/8,172.17.0.0/16,192.0.0.0/8'

docker run --rm -d --name postfix-relay -p 2525:25 \
	-e TX_SMTP_RELAY_HOST="${SMTP}" \
	-e TX_SMTP_RELAY_MYHOSTNAME=my.local \
	-e TX_SMTP_RELAY_USERNAME=${USERNAME} \
	-e TX_SMTP_RELAY_PASSWORD=${PASSWORD} \
	-e TX_SMTP_RELAY_NETWORKS=${TX_SMTP_RELAY_NETWORKS} \
	dreitier/postfix:${VERSION}
```
#### Testing
Test sending mail
```bash
# Run in your host's terminal
# Note the commands and responses from server
telnet localhost 2525
220 tx-smtp-relay.yourhost.com ESMTP Postfix
helo localhost
250 tx-smtp-relay.yourhost.com
mail from: noreply@yourhost.com
250 2.1.0 Ok
rcpt to: you@your.co
250 2.1.5 Ok
data
354 End data with <CR><LF>.<CR><LF>
Subject: Subject here...
The true story of swans singing Pink Floyed. 
.
250 2.0.0 Ok: queued as 982FF53C
quit
221 2.0.0 Bye
Connection closed by foreign host
```

Check the inbox of `you@your.co` and see you got the email.

### Docker container
You can find ready-to-run Docker containers at [dreitier/postfix](https://hub.docker.com/repository/docker/dreitier/postfix).

## Deploy Helm Chart
If you want to deploy this Docker image with Helm, you can use [postfix-helm](https://github.com/dreitier/postfix-helm).


## Development
### Creating new releases
A new release (artifact & Docker container) is automatically created when a new Git tag is pushed:

```bash
git tag x.y.z
git push origin x.y.z
```

## Support
This software is provided as-is. You can open an issue in GitHub's issue tracker at any time. But we can't promise to get it fixed in the near future.
If you need professionally support, consulting or a dedicated feature, please get in contact with us through our [website](https://dreitier.com).

## Contribution
Feel free to provide a pull request.

## License
This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## Thanks
This work is based on examples from https://github.com/applariat/kubernetes-postfix-relay-host 
