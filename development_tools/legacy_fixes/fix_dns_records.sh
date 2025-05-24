#!/bin/bash
# DNS automation for looking glass

# This would typically use your DNS provider's API
# For now, manual DNS configuration is required:

echo "Please add the following DNS records:"
echo "A    lg.infinitum-nihil.com    192.30.120.10"
echo "AAAA lg.infinitum-nihil.com    2620:71:4000::c01e:780a"
echo ""
echo "The anycast IP will automatically route users to their closest BGP speaker."
