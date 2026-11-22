# The staging search node (#364): the stock OpenSearch image plus one
# entrypoint that does what environment variables cannot. A Fly volume mounts
# owned by root, and the image runs as uid 1000 and refuses to run as root,
# so something has to start as root, hand the mount to uid 1000 and drop
# privileges. Everything else about the node is configured in fly.toml.
#
# The tag is the release .github/workflows/quality.yml and
# docker-compose.ci.yml pin. Bump the three together.
FROM opensearchproject/opensearch:3.2.0

USER root
COPY --chmod=0755 entrypoint.sh /usr/local/bin/cake-search-entrypoint.sh

# Setting ENTRYPOINT clears the CMD inherited from the base image.
ENTRYPOINT ["/usr/local/bin/cake-search-entrypoint.sh"]
CMD ["opensearch"]
