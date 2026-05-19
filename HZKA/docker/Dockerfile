# zkCross Docker Node
# Uses ethereum/client-go:v1.13.14 which supports Clique PoA sealing
# (geth 1.17+ removed Clique sealing support)
FROM ethereum/client-go:v1.13.14

# Install curl for peer discovery and bash for entrypoint
RUN apk add --no-cache curl bash

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8545 30303

ENTRYPOINT ["/entrypoint.sh"]
