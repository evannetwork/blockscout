defmodule Indexer.BlockRewardCatchup do
  @moduledoc """
  a special ketchup sauce for the block rewards that weren't mustarded by the conventional indexing hot dog
  """
  alias EthereumJSONRPC.{Blocks, FetchedBeneficiaries}
  alias Explorer.Chain
  alias Explorer.Chain.{Address, Block, Block.Reward, Import, Wei}
  alias Indexer.{AddressExtraction, CoinBalance, MintTransfer, Token, TokenTransfers, Tracer}
  alias Indexer.Address.{CoinBalances, TokenBalances}
  alias Indexer.Block.Fetcher.Receipts
  alias Indexer.Block.Transform

  @chunk_size 25

  def fetch_rewards do
    rewards = Chain.get_blocks_without_reward()
    |> break_into_chunks_of_block_numbers()
    |> Enum.flat_map(fn chunk ->
      chunk
      |> fetch_beneficiaries()
      |> fetch_block_rewards()
    end)

    Ecto.Multi.new()
    |> Ecto.Multi.insert_all(:insert_all, Reward, rewards)
    |> Explorer.Repo.transaction()
  end

  defp fetch_beneficiaries(chunk) do
    {chunk_start, chunk_end} = Enum.min_max(chunk)

    {:ok, %FetchedBeneficiaries{params_set: result}} =
      with :ignore <- EthereumJSONRPC.fetch_beneficiaries(chunk_start..chunk_end, json_rpc_named_arguments()) do
        {:ok, %FetchedBeneficiaries{params_set: MapSet.new()}}
      end

    result
  end

  defp fetch_block_rewards(beneficiaries) do
    Enum.map(beneficiaries, fn beneficiary ->
      case beneficiary.address_type do
        :validator ->
          validation_reward = fetch_validation_reward(beneficiary)

          {:ok, reward} = Wei.cast(beneficiary.reward)

          %{beneficiary | reward: Wei.sum(reward, validation_reward)}

        _ ->
          beneficiary
      end
    end)
  end

  defp fetch_validation_reward(beneficiary) do
    {:ok, accumulator} = Wei.cast(0)
    
    Chain.get_transactions_of_block_number(beneficiary.block_number)
    |> Enum.reduce(accumulator, fn t, acc ->
      {:ok, price_as_wei} = Wei.cast(t.gas_used) 
      price_as_wei |> Wei.mult(t.gas_price) |> Wei.sum(acc)
    end)
  end

  defp break_into_chunks_of_block_numbers(blocks) do
    Enum.chunk_while(
      blocks,
      [],
      fn block, acc ->
        if (acc == [] || hd(acc) + 1 == block.number) && length(acc) < @chunk_size do
          {:cont, [block.number | acc]}
        else
          {:cont, acc, [block.number]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, acc, []}
      end
    )
  end

  defp json_rpc_named_arguments() do
    Application.get_env(:explorer, :json_rpc_named_arguments)
  end
end
