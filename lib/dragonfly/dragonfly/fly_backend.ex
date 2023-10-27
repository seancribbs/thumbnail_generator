defmodule Dragonfly.FlyBackend do
  @behaviour Dragonfly.Backend

  alias Dragonfly.FlyBackend

  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Dragonfly.FlyBackend.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @derive {Inspect,
           only: [
             :host,
             :size,
             :image,
             :app,
             :runner_id,
             :machine_pid,
             :runner_node_basename,
             :runner_instance_id,
             :runner_private_ip,
             :runner_node_name,
             :connect_timeout
           ]}
  defstruct host: nil,
            env: %{},
            size: nil,
            image: nil,
            app: nil,
            token: nil,
            connect_timeout: nil,
            runner_id: nil,
            machine_pid: nil,
            runner_node_basename: nil,
            runner_instance_id: nil,
            runner_private_ip: nil,
            runner_node_name: nil

  @impl true
  def init(opts) do
    :global_group.monitor_nodes(true)
    conf = Enum.into(Application.get_env(:dragonfly, __MODULE__) || [], %{})
    [node_base | _] = node() |> to_string() |> String.split("@")

    default = %FlyBackend{
      app: System.get_env("FLY_APP_NAME"),
      image: System.get_env("FLY_IMAGE_REF"),
      token: System.get_env("FLY_API_TOKEN"),
      host: "https://api.machines.dev",
      size: "performance-2x",
      connect_timeout: 30_000,
      runner_node_basename: node_base,
    }

    state =
      default
      |> Map.merge(conf)
      |> Map.merge(Map.new(opts))

    for key <- [:token, :image, :host, :app] do
      unless Map.has_key?(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    parent = encode_pid(self())

    new_env =
      Map.merge(
        %{PHX_SERVER: "false", DRAGONFLY_PARENT: parent},
        state.env
      )

    new_state =
      %FlyBackend{state | env: new_env}

    {:ok, new_state}
  end

  def __rpc_spawn_link__(func) when is_function(func, 0) do
    func.()
    # Task.Supervisor.async(Dragonfly.FlyBackend.TaskSup, func)
  end

  def __rpc_spawn_link__({mod, func, args}) do
    apply(mod, func, args)
    # Task.Supervisor.async(Dragonfly.FlyBackend.TaskSup, mod, func, args)
  end

  @impl true
  def remote_spawn_link(%FlyBackend{} = state, term) do
    case term do
      func when is_function(func, 0) ->
        pid = Node.spawn_link(state.runner_node_name, __MODULE__, :__rpc_spawn_link__, [func])
        {:ok, pid, state}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        pid =
          Node.spawn_link(
            state.runner_node_name,
            __MODULE__,
            :__rpc_spawn_link__,
            [{mod, fun, args}]
          )

        {:ok, pid, state}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown do
    System.stop()
  end

  @impl true
  def remote_boot(%FlyBackend{} = state) do
    req =
      Req.post!("#{state.host}/v1/apps/#{state.app}/machines",
        auth: {:bearer, state.token},
        json: %{
          name: "#{state.app}-dragonfly-#{rand_id(20)}",
          config: %{
            image: state.image,
            size: state.size,
            auto_destroy: true,
            restart: %{policy: "no"},
            env: state.env
          }
        }
      )

    case req.body do
      %{"id" => id, "instance_id" => instance_id, "private_ip" => ip} ->
        new_state =
          %FlyBackend{
            state
            | runner_id: id,
              runner_instance_id: instance_id,
              runner_private_ip: ip,
              runner_node_name: :"#{state.runner_node_basename}@#{ip}"
          }

        machine_pid =
          receive do
            {:up, machine_pid} ->
              IO.inspect(Node.list())
              machine_pid
          after
            state.connect_timeout ->
              Logger.error("failed to connect to fly machine within #{state.connect_timeout}ms")
              exit(:timeout)
          end

        {:ok, %{new_state | machine_pid: machine_pid}}

      other ->
        {:error, other}
    end
  end

  @impl true
  def handle_info({:up, _}, state) do
    {:noreply, state}
  end

  def handle_info({:nodedown, down_node}, state) do
    if down_node == state.runner_node_name do
      {:stop, {:shutdown, :noconnection}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodeup, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    ^pid = state.machine_pid
    {:stop, {:shutdown, reason}, state}
  end

  defp rand_id(len) do
    len |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false) |> binary_part(0, len)
  end

  defp encode_pid(pid) when is_pid(pid) do
    pid |> :erlang.term_to_binary() |> Base.encode64()
  end
end
