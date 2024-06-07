#!/bin/bash

################

## Certbot ##
lets_server=https://acme-v02.api.letsencrypt.org/directory
auth_email=XXXXXXXXX
cloudflare_config=cloudflare.ini
## Scaleway API Token ##
scw_token=XXXXXXXXX
## Domains | golem.ai is domain extension by default ##
domains=("test")
## Multi Private Network (To access resources from an environment other than the Production PN environment) ##
multipns=("no")
## LBs ##
#test:0d1b714f-2767-4937-a9e5-4399cfd45338
private_lbs=("0d1b714f-2767-4937-a9e5-4399cfd45338")
zones=("fr-par-1")
################

for i in "${!domains[@]}"; do
  domain="${domains[$i]}"
  multipn="${multipns[$i]}"
  lb="${private_lbs[$i]}"
  zone="${zones[$i]}"

#Check the status of the last order
threshold_days=30

#Obtain certificate information
cert_info=$(echo -n Q | openssl s_client -servername $domain.golem.ai -connect $domain.golem.ai:443 2>/dev/null | openssl x509 -noout -dates -issuer)

#Extract the end date and the sender
not_after=$(echo "$cert_info" | grep 'notAfter' | cut -d= -f2)
issuer_full=$(echo "$cert_info" | grep 'issuer')
issuer=$(echo "$cert_info" | grep 'issuer' | sed -n 's/^.*O = \(.*\)/\1/p')

#Convert end date to timestamp
expiry_timestamp=$(date -d "$not_after" +%s)
current_timestamp=$(date +%s)
threshold_timestamp=$(date -d "+$threshold_days days" +%s)

#Check the condition of the expiry date and the issuer
echo $domain.golem.ai
echo $issuer_full
echo $not_after
echo "----"

ssl_manager () {

cat /etc/letsencrypt/live/$domain.golem.ai/fullchain.pem /etc/letsencrypt/live/$domain.golem.ai/privkey.pem > /tmp/$domain.golem.ai.pem

#Read certificate and private key files
CERTIFICATE=$(awk '{printf "%s\\n", $0}' < /tmp/$domain.golem.ai.pem)
CURRENT_DATE=$(date +'%Y-%m-%d')

#Create the JSON payload
JSON_PAYLOAD=$(cat <<EOF
{
  "name": "$domain.golem.ai-$CURRENT_DATE",
  "custom_certificate": {
    "certificate_chain": "$CERTIFICATE"
  }
}
EOF
)

#Update SSL Certificate on LB
RESPONSE_SSL_ID=$(curl -X POST "https://api.scaleway.com/lb/v1/zones/$zone/lbs/$lb/certificates" \
-H "X-Auth-Token: $scw_token" \
-H "Content-Type: application/json" \
-d "$JSON_PAYLOAD")

SSL_ID=$(echo $RESPONSE_SSL_ID | jq -r '.id')


#Get Frontend Information
RESPONSE_FRONTEND=$(curl -X GET "https://api.scaleway.com/lb/v1/zones/$zone/lbs/$lb/frontends" \
-H "X-Auth-Token: $scw_token")

BACKEND_ID=$(echo "$RESPONSE_FRONTEND" | jq -r --arg name "$domain.golem.ai" '.frontends[] | select(.name == $name) | .backend.id')
echo $BACKEND_ID

FRONTEND_ID=$(echo "$RESPONSE_FRONTEND" | jq -r --arg name "$domain.golem.ai" '.frontends[] | select(.name == $name) | .id')
echo $FRONTEND_ID

FRONTEND_INBOUND_PORT=$(echo "$RESPONSE_FRONTEND" | jq -r --arg name "$domain.golem.ai" '.frontends[] | select(.name == $name) | .inbound_port')
echo $FRONTEND_INBOUND_PORT

#JSON Update SSL Frontend
JSON_UPDATE_PAYLOAD=$(cat <<EOF
{
  "backend_id": "$BACKEND_ID",
  "enable_http3": true,
  "inbound_port": "$FRONTEND_INBOUND_PORT",
  "name": "$domain.golem.ai",
  "certificate_ids": [
     "$SSL_ID"
  ]
}
EOF
)

#Update SSL Frontend
curl -X PUT "https://api.scaleway.com/lb/v1/zones/$zone/frontends/$FRONTEND_ID" \
  -H "X-Auth-Token: $scw_token" \
  -H "Content-Type: application/json" \
  -d "$JSON_UPDATE_PAYLOAD"

#Delete Old Certificate
CERTIFICATES=$(curl -s -X GET "https://api.scaleway.com/lb/v1/zones/$zone/lbs/$lb/certificates" \
-H "X-Auth-Token: $scw_token")

#Extract certificates with a name matching $DOMAIN-date
CERTIFICATES=$(echo $CERTIFICATES | jq -c '.certificates[] | select(.name | startswith("'$domain.golem.ai'"))')

#Browse certificates and delete those with a date other than the current date
echo "$CERTIFICATES" | while IFS= read -r CERTIFICATE; do
  CERTIFICATE_NAME=$(echo $CERTIFICATE | jq -r '.name')
  CERTIFICATE_ID=$(echo $CERTIFICATE | jq -r '.id')

  #Extract the date from the certificate name (assumed to be in $DOMAIN-date format)
  CERTIFICATE_DATE=$(echo $CERTIFICATE_NAME | sed -E "s/^$domain.golem.ai-//")

  #Compare the certificate date with the current date
  if [[ "$CERTIFICATE_DATE" != "$CURRENT_DATE" ]]; then
    #Delete Certificate
    curl -s -X DELETE "https://api.scaleway.com/lb/v1/zones/$zone/certificates/$CERTIFICATE_ID" \
    -H "X-Auth-Token: $scw_token"
    echo "Certificat $CERTIFICATE_NAME (ID: $CERTIFICATE_ID) supprimé"
  fi
done
}


if [ $expiry_timestamp -le $threshold_timestamp ] || [ "$issuer" == "Kubernetes Ingress Controller Fake Certificate" ]; then
if [ "$multipn" == "yes" ] ; then
sudo certbot certonly --preferred-challenges=dns --email "$auth_email" --server $lets_server --dns-cloudflare --dns-cloudflare-credentials $cloudflare_config --agree-tos --non-interactive -d $domain.golem.ai -d $domain.otherdomain
ssl_manager
elif [ "$multipn" == "no" ]; then
sudo certbot certonly --preferred-challenges=dns --email "$auth_email" --server $lets_server --dns-cloudflare --dns-cloudflare-credentials $cloudflare_config --agree-tos --non-interactive -d $domain.golem.ai
ssl_manager
fi
fi
done
