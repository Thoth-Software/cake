# Use an official Elixir runtime as a parent image.
FROM elixir:latest

ARG USER_ID=1000
ARG GROUP_ID=1000

# Create non-root user matching host user
RUN groupadd --gid ${GROUP_ID} appgroup || true && \
    useradd --uid ${USER_ID} --gid ${GROUP_ID} --create-home appuser

# Install system packages as root
RUN apt-get update && \
  apt-get install -y postgresql-client inotify-tools

# Create app directory and copy code
RUN mkdir /app
COPY . /app
WORKDIR /app

# Install Hex package manager and compile
RUN mix local.hex --force
RUN mix do compile

# Expose Phoenix port
EXPOSE 4000

# Switch to non-root user for runtime
# USER appuser

# Start entrypoint
CMD ["sh", "entrypoint.sh"]
