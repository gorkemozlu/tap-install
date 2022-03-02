#!/bin/sh

# $1 - CN Object name
# $2 - username
# $3 - password

MSCA='changeme-ca-server'  # Internal Microsoft Certification Authority
Username=$2
Password=$3
csrConf=$4
certAtribe="Web Server SHA2"
MSCA_schema="http" # or https

function show_usage()
{
    echo "Script for retrive certificate from MS SubCA"
    echo "Usage: $0 <CN> [domain\\\\username] [password] [cnf_file]"
    echo " "
    echo "Example: $0 asd.vmw.local ""gorkem"" password req.cnf"
    exit 0
}

if [ -z "$1" ]
then
    show_usage
    exit 0
fi

if [ -z "$2" ]
then
    Username="workgroup\\foo"
    Password="bar"
fi

echo -e "\e[32m1. Generate private key...\e[0m"
openssl req -new -nodes -out generated/certs/$1.csr -keyout generated/certs/$1.key -config $csrConf
CERT=`cat generated/certs/$1.csr | tr -d '\n\r'`
DATA="Mode=newreq&CertRequest=${CERT}&C&TargetStoreFlags=0&SaveCert=yes"
CERT=`echo ${CERT} | sed 's/+/%2B/g'`
CERT=`echo ${CERT} | tr -s ' ' '+'`
CERTATTRIB="CertificateTemplate:${certAtribe}%0D%0A"

echo -e "\e[32m2. Request cert...\e[0m"
OUTPUTLINK=`curl -k -u "${Username}":${Password} --ntlm \
"${MSCA_schema}://${MSCA}/certsrv/certfnsh.asp" \
-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
-H 'Accept-Encoding: gzip, deflate' \
-H 'Accept-Language: en-US,en;q=0.5' \
-H 'Connection: keep-alive' \
-H "Host: ${MSCA}" \
-H "Referer: ${MSCA_schema}://${MSCA}/certsrv/certrqxt.asp" \
-H 'User-Agent: Mozilla/5.0 (Windows NT 6.3; WOW64; Trident/7.0; rv:11.0) like Gecko' \
-H 'Content-Type: application/x-www-form-urlencoded' \
--data "Mode=newreq&CertRequest=${CERT}&CertAttrib=${CERTATTRIB}&TargetStoreFlags=0&SaveCert=yes&ThumbPrint=" | grep -A 1 'function handleGetCert() {' | tail -n 1 | cut -d '"' -f 2`
CERTLINK="${MSCA_schema}://${MSCA}/certsrv/${OUTPUTLINK}"

echo -e "\e[32m3. Retrive cert: $CERTLINK\e[0m"
curl -k -u "${Username}":${Password} --ntlm $CERTLINK \
-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
-H 'Accept-Encoding: gzip, deflate' \
-H 'Accept-Language: en-US,en;q=0.5' \
-H 'Connection: keep-alive' \
-H "Host: ${MSCA}" \
-H "Referer: ${MSCA_schema}://${MSCA}/certsrv/certrqxt.asp" \
-H 'User-Agent: Mozilla/5.0 (Windows NT 6.3; WOW64; Trident/7.0; rv:11.0) like Gecko' \
-H 'Content-Type: application/x-www-form-urlencoded' > generated/certs/$1.pem

echo -e "\e[32m4. Verifying cert for $1\e[0m"
md5crt=$(openssl x509 -modulus -noout -in generated/certs/$1.pem | openssl md5|awk '{print $2}')
md5key=$(openssl rsa -noout -modulus -in generated/certs/$1.key | openssl md5|awk '{print $2}')
echo $md5crt
echo $md5key
if [ "$md5crt" == "$md5key" ] ;
    then
        echo -e "\e[32mWell done. Have a nice day.\e[0m"
        exit 0
    else
        echo -e "\e[31;47mError code: $?. Stopping.\e[0m"
        exit 1
fi
