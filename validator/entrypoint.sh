#!/bin/bash

ERROR="[ ERROR ]"
WARN="[ WARN ]"
INFO="[ INFO ]"

CLIENT="prysm"
NETWORK="prater"

function ensure_envs_exist() {
    [ -z "${BEACON_RPC_PROVIDER}" ] && { echo "${ERROR} BEACON_RPC_PROVIDER is not set"; exit 1; }
    [ -z "${BEACON_RPC_GATEWAY_PROVIDER}" ] && { echo "${ERROR} BEACON_RPC_GATEWAY_PROVIDER is not set"; exit 1; }
    [ -z "${HTTP_WEB3SIGNER}" ] && { echo "${ERROR} HTTP_WEB3SIGNER is not set"; exit 1; }
    [ -z "${PUBLIC_KEYS_FILE}" ] && { echo "${ERROR} PUBLIC_KEYS_FILE is not set"; exit 1; }
    [ -z "${WALLET_DIR}" ] && { echo "${ERROR} WALLET_DIR is not set"; exit 1; }
    [ -z "${SUPERVISOR_CONF}" ] && { echo "${ERROR} SUPERVISOR_CONF is not set"; exit 1; }
    [ -z "$GRAFFITI" ] && echo "$ERROR: GRAFFITI is not set" && exit 1
    [ ! -z "$GRAFFITI" ] && EXTRA_OPTS="${EXTRA_OPTS} --graffiti=\"${GRAFFITI}\"" # Concatenate EXTRA_OPTS with existing var, otherwise supervisor will throw error
}

# - Endpoint: http://web3signer.web3signer-prater.dappnode:9000/eth/v1/keystores
# - Returns:
# { "data": [{
#     "validating_pubkey": "0x93247f2209abcacf57b75a51dafae777f9dd38bc7053d1af526f220a7489a6d3a2753e5f3e8b1cfe39b56f43611df74a",
#     "derivation_path": "m/12381/3600/0/0/0",
#     "readonly": true
#     }]
# }
function get_public_keys() {
    # Try for 3 minutes    
    while true; do
        if WEB3SIGNER_RESPONSE=$(curl -s -w "%{http_code}" -X GET -H "Content-Type: application/json" -H "Host: validator.${CLIENT}-${NETWORK}.dappnode" \
        --retry 60 --retry-delay 3 --retry-connrefused "${HTTP_WEB3SIGNER}/eth/v1/keystores"); then

            HTTP_CODE=${WEB3SIGNER_RESPONSE: -3}
            CONTENT=$(echo ${WEB3SIGNER_RESPONSE} | head -c-4)

            case ${HTTP_CODE} in
                200)
                    PUBLIC_KEYS_API=$(echo ${CONTENT} | jq -r 'try .data[].validating_pubkey')
                    if [ -z "${PUBLIC_KEYS_API}" ]; then
                        sed -i 's/autostart=true/autostart=false/g' $SUPERVISOR_CONF
                        { echo "${WARN} no public keys found on web3signer"; break; }
                    else 
                        sed -i 's/autostart=false/autostart=true/g' $SUPERVISOR_CONF
                        write_public_keys
                        { echo "${INFO} found public keys: $PUBLIC_KEYS_API"; break; }
                    fi
                    ;;
                403)
                    if [[ "${CONTENT}" == *"Host not authorized"* ]]; then
                        sed -i 's/autostart=true/autostart=false/g' $SUPERVISOR_CONF
                        { echo "${WARN} client not authorized to access the web3signer api"; break; }
                    fi
                    break
                    ;;
                *)
                    { echo "${ERROR} ${CONTENT} HTTP code ${HTTP_CODE} from ${HTTP_WEB3SIGNER}"; break; }
                    ;;
            esac
            break
        else
            { echo "${WARN} web3signer not available"; continue; }
        fi
    done
}

# Ensure file will exists
function clean_public_keys() {
    rm -rf ${PUBLIC_KEYS_FILE}
    touch ${PUBLIC_KEYS_FILE}
}

# Writes public keys
# - by new line separated
# - creates file if it does not exist
function write_public_keys() {
    echo "${INFO} writing public keys to file"
    for PUBLIC_KEY in ${PUBLIC_KEYS_API}; do
        if [ ! -z "${PUBLIC_KEY}" ]; then
            echo "${INFO} adding public key: $PUBLIC_KEY"
            echo "${PUBLIC_KEY}" >> ${PUBLIC_KEYS_FILE}
        else
            echo "${WARN} empty public key"
        fi
    done
}

########
# MAIN #
########

ensure_envs_exist

# Migrate if required
validator accounts list \
    --wallet-dir="$WALLET_DIR" \
    --wallet-password-file="${WALLET_DIR}/walletpassword.txt" \
    --prater \
    --accept-terms-of-use \
    && { echo "${INFO} found validators, starging migration"; eth2-migrate.sh & wait $!; } \
    || { echo "${INFO} validators not found, no migration needed"; }

clean_public_keys

get_public_keys

# Execute supervisor with current environment!
exec supervisord -c $SUPERVISOR_CONF