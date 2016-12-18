#!/bin/bash

subscriptionId="subscription().subscriptionId"
tenantId="subscription().tenantId"
resourceGroup="resourceGroup().name"
appPrincipalId="parameters('appPrincipalId')"
password="parameters('servicePrincipalPassword')"
virtualNetwork="variables('vnetName')"
clusterName="parameters('clusterName')"
lbName="variables('lbName')"

cat <<EOF >"$FWDIR/conf/azure-ha.json"
{
  "debug": false,
  "subscriptionId": "$subscriptionId",
  "resourceGroup": "$resourceGroup",
  "credentials": {
    "tenant": "$tenantId",
    "grant_type": "client_credentials",
    "client_id": "$appPrincipalId",
    "client_secret": "$password"
  },
  "virtualNetwork": "$virtualNetwork",
  "clusterName": "$clusterName",
  "lbName": "$lbName"
}
EOF

adminPassword="parameters('adminPassword')"
sicKey="parameters('sicKey')"
conf="install_security_gw=true"
conf="${conf}&install_ppak=true"
conf="${conf}&gateway_cluster_member=true"
conf="${conf}&install_security_managment=false"
conf="${conf}&ftw_sic_key=$sicKey"

config_system -s "$conf"
shutdown -r now
