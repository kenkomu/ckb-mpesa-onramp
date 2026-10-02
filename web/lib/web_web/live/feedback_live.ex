defmodule WebWeb.FeedbackLive do
  @moduledoc """
  The pilot's feedback form -- the Week 5 "user testing" deliverable the
  grant plan explicitly scores. Deliberately minimal: no admin UI,
  submissions are read by `ssh`-ing into the VPS and reading
  `priv/feedback/submissions.jsonl` directly (see Web.Feedback.Store).

  Reuses the same `phx-hook="Wallet"` pattern every other page uses so a
  connected wallet's address can be attached to the submission --
  correlates feedback with a real pilot session without needing a login
  system.
  """

  use WebWeb, :live_view

  alias Web.Feedback.Store

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(wallet: nil, submitted: false)
     |> assign(form: to_form(%{"broke" => "", "confusing" => "", "use_again" => "", "comment" => ""}))}
  end

  def handle_event("wallet_ready", %{"address" => address}, socket) do
    {:noreply, assign(socket, wallet: address)}
  end

  def handle_event("wallet_error", _params, socket), do: {:noreply, socket}

  def handle_event("submit_feedback", params, socket) do
    fields = %{
      "broke" => Map.get(params, "broke", ""),
      "confusing" => Map.get(params, "confusing", ""),
      "use_again" => Map.get(params, "use_again", ""),
      "comment" => Map.get(params, "comment", ""),
      "wallet_address" => socket.assigns.wallet
    }

    Store.submit(fields)
    {:noreply, assign(socket, submitted: true)}
  end

  def render(assigns) do
    ~H"""
    <div id="wallet" phx-hook="Wallet" class="max-w-xl mx-auto space-y-6">
      <div>
        <div class="font-mono text-xs uppercase tracking-widest text-primary font-semibold mb-1">
          Pilot
        </div>
        <h1 class="font-display text-3xl font-bold tracking-tight">Feedback</h1>
        <p class="text-sm text-base-content/70 mt-1">
          Testing Bitshada on testnet? Tell us what broke, what confused you, and whether you'd use it again.
        </p>
      </div>

      <div :if={@submitted} class="alert alert-success shadow-sm">
        <.icon name="hero-check-circle" class="size-5" />
        <span class="text-sm">Thanks -- your feedback was recorded.</span>
      </div>

      <div :if={!@submitted} class="card bg-base-200 border border-base-300 shadow-sm">
        <div class="card-body">
          <.form for={@form} phx-submit="submit_feedback" class="space-y-4">
            <label class="form-control">
              <span class="label-text text-xs text-base-content/60 mb-1">What broke, if anything?</span>
              <textarea name="broke" class="textarea textarea-bordered w-full" rows="3"></textarea>
            </label>
            <label class="form-control">
              <span class="label-text text-xs text-base-content/60 mb-1">What confused you?</span>
              <textarea name="confusing" class="textarea textarea-bordered w-full" rows="3"></textarea>
            </label>
            <label class="form-control">
              <span class="label-text text-xs text-base-content/60 mb-1">Would you use this again?</span>
              <select name="use_again" class="select select-bordered w-full">
                <option value="yes">Yes</option>
                <option value="maybe">Maybe</option>
                <option value="no">No</option>
              </select>
            </label>
            <label class="form-control">
              <span class="label-text text-xs text-base-content/60 mb-1">Anything else?</span>
              <textarea name="comment" class="textarea textarea-bordered w-full" rows="2"></textarea>
            </label>
            <p :if={@wallet} class="text-xs text-base-content/50 font-mono">
              Attached wallet: {String.slice(@wallet, 0, 10)}...
            </p>
            <.button type="submit" class="btn-primary w-full">Send feedback</.button>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
