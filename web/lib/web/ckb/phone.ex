defmodule Web.Ckb.Phone do
  @moduledoc """
  Validates and normalizes Kenyan mobile numbers.

  Accepts 07xx / 01xx, 7xx / 1xx, 2547xx / 2541xx and +254... forms
  (spaces and dashes ignored) and always returns the international
  form without a plus, e.g. "254712345678" -- so the same number
  always hashes to the same recipient_hash on-chain.
  """

  @doc "Returns `{:ok, \"2547XXXXXXXX\"}` or `:error`."
  def normalize(input) when is_binary(input) do
    digits = input |> String.replace(~r/[\s\-()]/, "") |> String.trim_leading("+")

    local =
      cond do
        String.starts_with?(digits, "254") -> String.slice(digits, 3..-1//1)
        String.starts_with?(digits, "0") -> String.slice(digits, 1..-1//1)
        true -> digits
      end

    with true <- Regex.match?(~r/^[17]\d{8}$/, local),
         false <- all_same_digit?(String.slice(local, 1..-1//1)) do
      {:ok, "254" <> local}
    else
      _ -> :error
    end
  end

  def normalize(_), do: :error

  # Rejects obvious fakes like 0700000000 or 0711111111.
  defp all_same_digit?(digits), do: digits |> String.graphemes() |> Enum.uniq() |> length() == 1

  @doc "Display form: 0712 345 678."
  def display("254" <> local) do
    "0" <> String.slice(local, 0, 3) <> " " <> String.slice(local, 3, 3) <> " " <> String.slice(local, 6, 3)
  end

  def display(other), do: other
end
