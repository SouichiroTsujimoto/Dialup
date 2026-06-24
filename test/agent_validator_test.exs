defmodule Dialup.Agent.ValidatorTest do
  use ExUnit.Case, async: true

  alias Dialup.Agent.Validator

  test "validates enum constraints after validating the parameter type" do
    action = %{params: %{product_id: {:integer, enum: [1, 2, 3]}}}

    assert {:ok, %{"product_id" => 2}} = Validator.validate(action, %{"product_id" => 2})

    assert {:error,
            [
              %{
                "field" => "product_id",
                "message" => "must be one of the declared enum values"
              }
            ]} = Validator.validate(action, %{"product_id" => 99})

    assert {:error, [%{"field" => "product_id", "message" => "must be integer"}]} =
             Validator.validate(action, %{"product_id" => "2"})
  end
end
