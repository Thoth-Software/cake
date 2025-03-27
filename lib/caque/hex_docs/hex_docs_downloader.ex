defmodule HexDocsDownloader do
  require Logger

  def download(package) do
    System.cmd("mix", ["hex.docs", "fetch", package])
    :ok
  end

  def fetch_and_save_package_list do
    url = "https://hex.pm/api/packages?page="
    fetch_and_save(url, 1)
  end

  defp fetch_and_save(url, page_number) do
    case fetch_package_list_page(url, page_number) do
      {:ok, []} ->
        IO.puts("No more packages found, finished fetching.")
        :ok

      {:ok, packages} ->
        names = Enum.map(packages, fn package -> package["name"] end)
        save_to_file(names)
        fetch_and_save(url, page_number + 1)

      {:error, reason} ->
        IO.puts("Error fetching page #{page_number}: #{inspect(reason)}")
        :error
    end
  end

  defp fetch_package_list_page(url, page_number) do
    case Req.get("#{url}#{page_number}") do
      {:ok, response} ->
        case Jason.decode(response.body) do
          {:ok, packages} -> {:ok, packages}
          {:error, _reason} -> {:error, "Failed to decode JSON"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_to_file(names) do
    file_path = "package_names.json"

    # If the file already exists, we append to it; otherwise, we create it
    case File.read(file_path) do
      {:ok, existing_content} ->
        case Jason.decode(existing_content) do
          {:ok, existing_names} ->
            new_names = existing_names ++ names
            write_to_file(file_path, new_names)

          {:error, _reason} ->
            IO.puts("Error decoding existing content, overwriting file.")
            write_to_file(file_path, names)
        end

      {:error, _reason} ->
        write_to_file(file_path, names)
    end
  end

  defp write_to_file(file_path, data) do
    case Jason.encode(data) do
      {:ok, json} ->
        File.write(file_path, json)
        IO.puts("Package names saved to #{file_path}")

      {:error, reason} ->
        IO.puts("Failed to encode data to JSON. Reason: #{inspect(reason)}")
    end
  end
end
