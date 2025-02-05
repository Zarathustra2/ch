defmodule Ch.Query do
  @moduledoc "Query struct wrapping the SQL statement."
  defstruct [:statement, :command]

  @type t :: %__MODULE__{statement: iodata, command: atom}

  @doc false
  @spec build(iodata, atom) :: t
  def build(statement, command \\ nil) when is_atom(command) do
    %__MODULE__{statement: statement, command: command || extract_command(statement)}
  end

  statements = [
    {"SELECT", :select},
    {"INSERT", :insert},
    {"CREATE", :create},
    {"ALTER", :alter},
    {"DELETE", :delete},
    {"SYSTEM", :system},
    {"SHOW", :show},
    # as of clickhouse 22.8, WITH is only allowed in SELECT
    # https://clickhouse.com/docs/en/sql-reference/statements/select/with/
    {"WITH", :select},
    {"GRANT", :grant},
    {"EXPLAIN", :explain},
    {"REVOKE", :revoke},
    {"ATTACH", :attach},
    {"CHECK", :check},
    {"DESCRIBE", :describe},
    {"DETACH", :detach},
    {"DROP", :drop},
    {"EXISTS", :exists},
    {"KILL", :kill},
    {"OPTIMIZE", :optimize},
    {"RENAME", :rename},
    {"EXCHANGE", :exchange},
    {"SET", :set},
    {"TRUNCATE", :truncate},
    {"USE", :use},
    {"WATCH", :watch}
  ]

  defp extract_command(statement)

  for {statement, command} <- statements do
    defp extract_command(unquote(statement) <> _), do: unquote(command)
    defp extract_command(unquote(String.downcase(statement)) <> _), do: unquote(command)
  end

  defp extract_command(<<whitespace, rest::bytes>>) when whitespace in [?\s, ?\t, ?\n] do
    extract_command(rest)
  end

  defp extract_command([first_segment | _] = statement) do
    extract_command(first_segment) || extract_command(IO.iodata_to_binary(statement))
  end

  defp extract_command(_other), do: nil
end

defimpl DBConnection.Query, for: Ch.Query do
  alias Ch.{Query, Result, RowBinary}

  @spec parse(Query.t(), Keyword.t()) :: Query.t()
  def parse(query, _opts), do: query

  @spec describe(Query.t(), Keyword.t()) :: Query.t()
  def describe(query, _opts), do: query

  @spec encode(Query.t(), params, Keyword.t()) :: {query_params, Mint.Types.headers(), body}
        when raw: iodata | Enumerable.t(),
             params: map | [term] | [row :: [term]] | {:raw, raw},
             query_params: [{String.t(), String.t()}],
             body: raw

  def encode(%Query{command: :insert, statement: statement}, {:raw, data}, _opts) do
    body =
      case data do
        _ when is_list(data) or is_binary(data) -> [statement, ?\n | data]
        _ -> Stream.concat([[statement, ?\n]], data)
      end

    {_query_params = [], _extra_headers = [], body}
  end

  def encode(%Query{command: :insert, statement: statement}, params, opts) do
    cond do
      names = Keyword.get(opts, :names) ->
        types = Keyword.fetch!(opts, :types)
        header = RowBinary.encode_names_and_types(names, types)
        data = RowBinary.encode_rows(params, types)
        {_query_params = [], _extra_headers = [], [statement, ?\n, header | data]}

      format_row_binary?(statement) ->
        types = Keyword.fetch!(opts, :types)
        data = RowBinary.encode_rows(params, types)
        {_query_params = [], _extra_headers = [], [statement, ?\n | data]}

      true ->
        {query_params(params), _extra_headers = [], statement}
    end
  end

  def encode(%Query{statement: statement}, params, opts) do
    types = Keyword.get(opts, :types)
    default_format = if types, do: "RowBinary", else: "RowBinaryWithNamesAndTypes"
    format = Keyword.get(opts, :format) || default_format
    {query_params(params), [{"x-clickhouse-format", format}], statement}
  end

  defp format_row_binary?(statement) when is_binary(statement) do
    statement |> String.trim_trailing() |> String.ends_with?("RowBinary")
  end

  defp format_row_binary?(statement) when is_list(statement) do
    statement
    |> IO.iodata_to_binary()
    |> format_row_binary?()
  end

  @spec decode(Query.t(), [response], Keyword.t()) :: Result.t()
        when response: Mint.Types.status() | Mint.Types.headers() | binary
  def decode(%Query{command: :insert}, responses, _opts) do
    [_status, headers | _data] = responses

    num_rows =
      if summary = get_header(headers, "x-clickhouse-summary") do
        %{"written_rows" => written_rows} = Jason.decode!(summary)
        String.to_integer(written_rows)
      end

    %Result{num_rows: num_rows, rows: nil, command: :insert, headers: headers}
  end

  def decode(%Query{command: command}, responses, opts) when is_list(responses) do
    # TODO potentially fails on x-progress-headers
    [_status, headers | data] = responses

    case get_header(headers, "x-clickhouse-format") do
      "RowBinary" ->
        types = Keyword.fetch!(opts, :types)
        rows = data |> IO.iodata_to_binary() |> RowBinary.decode_rows(types)
        %Result{num_rows: length(rows), rows: rows, command: command, headers: headers}

      "RowBinaryWithNamesAndTypes" ->
        rows = data |> IO.iodata_to_binary() |> RowBinary.decode_rows()
        %Result{num_rows: length(rows), rows: rows, command: command, headers: headers}

      _other ->
        %Result{rows: data, command: command, headers: headers}
    end
  end

  # TODO merge :stream `decode/3` with "normal" `decode/3` clause above
  @spec decode(Query.t(), {:stream, nil, responses}, Keyword.t()) :: responses
        when responses: [Mint.Types.response()]
  def decode(_query, {:stream, nil, responses}, _opts), do: responses

  @spec decode(Query.t(), {:stream, [atom], [Mint.Types.response()]}, Keyword.t()) :: [[term]]
  def decode(_query, {:stream, types, responses}, _opts) do
    decode_stream_data(responses, types)
  end

  defp decode_stream_data([{:data, _ref, data} | rest], types) do
    [RowBinary.decode_rows(data, types) | decode_stream_data(rest, types)]
  end

  defp decode_stream_data([_ | rest], types), do: decode_stream_data(rest, types)
  defp decode_stream_data([] = done, _types), do: done

  defp get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, value} -> value
      nil = not_found -> not_found
    end
  end

  defp query_params(params) when is_map(params) do
    Enum.map(params, fn {k, v} -> {"param_#{k}", encode_param(v)} end)
  end

  defp query_params(params) when is_list(params) do
    params
    |> Enum.with_index()
    |> Enum.map(fn {v, idx} -> {"param_$#{idx}", encode_param(v)} end)
  end

  defp encode_param(n) when is_integer(n), do: Integer.to_string(n)
  defp encode_param(f) when is_float(f), do: Float.to_string(f)
  defp encode_param(b) when is_binary(b), do: b
  defp encode_param(b) when is_boolean(b), do: Atom.to_string(b)
  defp encode_param(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp encode_param(%Date{} = date), do: Date.to_iso8601(date)
  defp encode_param(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)

  defp encode_param(%DateTime{time_zone: "Etc/UTC", microsecond: microsecond} = dt) do
    seconds = DateTime.to_unix(dt, :second)

    case microsecond do
      {val, size} when size > 0 ->
        size = round(:math.pow(10, size))
        Float.to_string((seconds * size + val) / size)

      _ ->
        Integer.to_string(seconds)
    end
  end

  defp encode_param(%DateTime{} = dt) do
    raise ArgumentError, "non-UTC timezones are not supported for encoding: #{dt}"
  end

  defp encode_param(tuple) when is_tuple(tuple) do
    IO.iodata_to_binary([?(, encode_array_params(Tuple.to_list(tuple)), ?)])
  end

  defp encode_param(a) when is_list(a) do
    IO.iodata_to_binary([?[, encode_array_params(a), ?]])
  end

  defp encode_param(m) when is_map(m) do
    IO.iodata_to_binary([?{, encode_map_params(Map.to_list(m)), ?}])
  end

  defp encode_array_params([last]), do: encode_array_param(last)

  defp encode_array_params([s | rest]) do
    [encode_array_param(s), ?, | encode_array_params(rest)]
  end

  defp encode_array_params([] = empty), do: empty

  defp encode_map_params([last]), do: encode_map_param(last)

  defp encode_map_params([kv | rest]) do
    [encode_map_param(kv), ?, | encode_map_params(rest)]
  end

  defp encode_map_params([] = empty), do: empty

  defp encode_array_param(s) when is_binary(s) do
    [?', escape_array_param(s), ?']
  end

  defp encode_array_param(%s{} = param) when s in [Date, NaiveDateTime] do
    [?', encode_param(param), ?']
  end

  defp encode_array_param(v), do: encode_param(v)

  defp encode_map_param({k, v}) do
    [encode_array_param(k), ?:, encode_array_param(v)]
  end

  @compile inline: [escape_array_param: 1]
  defp escape_array_param(s) do
    escape_array_param(s, 0, s, [])
  end

  @dialyzer {:no_improper_lists, escape_array_param: 4, escape_array_param: 5}

  @doc false
  # based on based on https://github.com/elixir-plug/plug/blob/main/lib/plug/html.ex#L41-L80
  def escape_array_param(binary, skip, original, acc)

  escapes = [{?', "\\'"}, {?\\, "\\\\"}]

  for {match, insert} <- escapes do
    def escape_array_param(<<unquote(match), rest::bits>>, skip, original, acc) do
      escape_array_param(rest, skip + 1, original, [acc | unquote(insert)])
    end
  end

  def escape_array_param(<<_char, rest::bits>>, skip, original, acc) do
    escape_array_param(rest, skip, original, acc, 1)
  end

  def escape_array_param(<<>>, _skip, _original, acc) do
    acc
  end

  for {match, insert} <- escapes do
    defp escape_array_param(<<unquote(match), rest::bits>>, skip, original, acc, len) do
      part = binary_part(original, skip, len)
      escape_array_param(rest, skip + len + 1, original, [acc, part | unquote(insert)])
    end
  end

  defp escape_array_param(<<_char, rest::bits>>, skip, original, acc, len) do
    escape_array_param(rest, skip, original, acc, len + 1)
  end

  defp escape_array_param(<<>>, 0, original, _acc, _len) do
    original
  end

  defp escape_array_param(<<>>, skip, original, acc, len) do
    [acc | binary_part(original, skip, len)]
  end
end

defimpl String.Chars, for: Ch.Query do
  def to_string(%{statement: statement}) do
    IO.iodata_to_binary(statement)
  end
end
