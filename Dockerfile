# Use an official Elixir runtime as a parent image.
FROM elixir:latest

EXPOSE 4000

RUN apt-get update && \
  apt-get install -y postgresql-client && \
  rm -rf /var/lib/apt/lists/*

# Install Hex package manager.
RUN mix local.hex --force && \
  mix local.rebar --force

  apt-get install -y postgresql-client inotify-tools

# Create app directory and copy the Elixir projects into it.
RUN mkdir /app
COPY . /app
WORKDIR /app

# Compile the project.
RUN mix deps.get
RUN mix do compile

CMD ["/app/entrypoint.sh"]
