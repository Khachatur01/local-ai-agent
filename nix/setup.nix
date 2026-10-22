# One-time provisioning: pull the base models and build the derived ones.
#
# This is deliberately separate from `agent` so launching the agent never does
# hidden mutating work and never blocks on a 22GB download.
{ mkScript }:

mkScript {
  name = "local-ai-setup";

  text = ''
    ensure_server

    ensure_model "$AGENT_MODEL" "$BASE_MODEL" "$NUM_CTX" "$AGENT_NUM_GPU" \
      "~22GB download"

    # See nix/settings.nix for why the fast model must stay off the GPU.
    ensure_model "$FAST_MODEL" "$FAST_BASE_MODEL" "$FAST_NUM_CTX" "$FAST_NUM_GPU" \
      "~1.4GB download"

    say ""
    say "setup complete. Next: 'local-ai-doctor' to check the server settings,"
    say "then 'agent' from any project."
  '';
}
