# Make sure to have docker installed
# This is the opensearch container
docker pull opensearchproject/opensearch
docker pull postgres:14

# Clone the repo and slide on in
git clone git@github.com:caleb-bb/caque.git
cd caque

# Phoenix stuff
mix ecto.create
mix ecto.setup
mix deps.get

# Ride it like you stole it
docker-compose up -d
