defmodule HexDocsDownloader do
  require Logger
  @hexdocs_base "https://hexdocs.pm/"

  def download(package) do
    url = "#{@hexdocs_base}#{package}/"
    output_dir = "hexdocs/#{package}"
    File.mkdir_p!(output_dir)

    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.write!("#{output_dir}/index.html", body)
        Logger.info("Downloaded #{package} docs successfully.")

      {:error, reason} ->
        Logger.error("Failed to download #{package} docs: #{inspect(reason)}")
    end
  end
end
