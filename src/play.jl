#####
##### An MCTS-based player
#####

abstract type AbstractPlayer{Game} end

"""
    think(::AbstractPlayer, state, turn_number::Int)

Return an `(a, π)` pair where `a` is the chosen action and
`π` a probability distribution over available actions.

Note that `a` does not have to be drawn from `π`.
"""
function think(player::AbstractPlayer, state, turn)
  @unimplemented
end

function reset!(player::AbstractPlayer)
  return
end

#####
##### Random Player
#####

struct RandomPlayer{Game} <: AbstractPlayer{Game} end

function think(player::RandomPlayer, state, turn)
  actions = GI.available_actions(state)
  n = length(actions)
  π = ones(n) ./ length(actions)
  return rand(actions), π
end

#####
##### MCTS with random oracle
#####

function RandomMctsPlayer(::Type{G}, params::MctsParams) where G
  oracle = MCTS.RandomOracle{G}()
  mcts = MCTS.Env{G}(oracle, nworkers=1, cpuct=params.cpuct)
  return MctsPlayer(mcts, params.num_iters_per_turn,
    τ=params.temperature,
    nα=params.dirichlet_noise_nα,
    ϵ=params.dirichlet_noise_ϵ)
end

#####
##### MCTS Player
#####

struct MctsPlayer{G, M} <: AbstractPlayer{G}
  mcts :: M
  niters :: Int
  τ :: StepSchedule{Float64} # Temperature
  nα :: Float64 # Dirichlet noise parameter
  ϵ :: Float64 # Dirichlet noise weight
  function MctsPlayer(mcts::MCTS.Env{G}, niters; τ, nα, ϵ) where G
    new{G, typeof(mcts)}(mcts, niters, τ, nα, ϵ)
  end
end

# Alternative constructor
function MctsPlayer(oracle::MCTS.Oracle{G}, params::MctsParams) where G
  fill_batches = false
  if isa(oracle, AbstractNetwork)
    oracle = Network.copy(oracle, on_gpu=params.use_gpu, test_mode=true)
    params.use_gpu && (fill_batches = true)
  end
  mcts = MCTS.Env{G}(oracle,
    nworkers=params.num_workers,
    fill_batches=fill_batches,
    cpuct=params.cpuct)
  return MctsPlayer(mcts, params.num_iters_per_turn,
    τ=params.temperature,
    nα=params.dirichlet_noise_nα,
    ϵ=params.dirichlet_noise_ϵ)
end

function fix_probvec(π)
  π = convert(Vector{Float32}, π)
  s = sum(π)
  if !(s ≈ 1)
    if iszero(s)
      n = length(π)
      π = ones(Float32, n) ./ n
    else
      π ./= s
    end
  end
  return π
end

function think(p::MctsPlayer, state, turn)
  if iszero(p.niters)
    # Special case: use the oracle directly instead of MCTS
    actions = GI.available_actions(state)
    board = GI.canonical_board(state)
    π_mcts, _ = MCTS.evaluate(p.mcts.oracle, board, actions)
  else
    MCTS.explore!(p.mcts, state, p.niters)
    actions, π_mcts = MCTS.policy(p.mcts, state, τ=p.τ[turn])
  end
  if iszero(p.ϵ)
    π_exp = π_mcts
  else
    n = length(π_mcts)
    noise = Dirichlet(n, p.nα / n)
    π_exp = (1 - p.ϵ) * π_mcts + p.ϵ * rand(noise)
  end
  a = actions[rand(Categorical(fix_probvec(π_exp)))]
  return a, π_mcts
end

function reset!(player::MctsPlayer)
  MCTS.reset!(player.mcts)
end

#####
##### MCTS players can play against each other
#####

# Returns the reward and the game length
function play(
    white::AbstractPlayer{Game}, black::AbstractPlayer{Game}, memory=nothing
  ) :: Float64 where Game
  state = Game()
  nturns = 0
  while true
    z = GI.white_reward(state)
    if !isnothing(z)
      isnothing(memory) || push_game!(memory, z, nturns)
      return z
    end
    player = GI.white_playing(state) ? white : black
    a, π = think(player, state, nturns)
    if !isnothing(memory)
      cboard = GI.canonical_board(state)
      push_sample!(memory, cboard, π, GI.white_playing(state), nturns)
    end
    GI.play!(state, a)
    nturns += 1
  end
end

self_play!(player, memory) = play(player, player, memory)

#####
##### Evaluate two players against each other
#####

"""
    @enum ColorPolicy ALTERNATE_COLORS BASELINE_WHITE CONTENDER_WHITE

Policy for attributing colors in a duel between a baseline and a contender.
"""
@enum ColorPolicy ALTERNATE_COLORS BASELINE_WHITE CONTENDER_WHITE

"""
    pit(handler, baseline, contender, ngames)

Evaluate two players against each other on a series of games.

# Arguments

  - `handler`: this function is called after each simulated
     game with two arguments: the game number `i` and the collected reward `z`
     for the contender player
  - `baseline, contender :: AbstractPlayer`
  - `ngames`: number of games to play

# Optional keyword arguments
  - `reset_every`: if set, players are reset every `reset_every` games
  - `color_policy`: determine the [`ColorPolicy`](@ref),
    which is `ALTERNATE_COLORS` by default
"""
function pit(
    handler, baseline::AbstractPlayer, contender::AbstractPlayer, num_games;
    reset_every=nothing, color_policy=ALTERNATE_COLORS)
  baseline_white = (color_policy != CONTENDER_WHITE)
  zsum = 0.
  for i in 1:num_games
    white = baseline_white ? baseline : contender
    black = baseline_white ? contender : baseline
    z = play(white, black)
    baseline_white && (z = -z)
    zsum += z
    handler(i, z)
    if !isnothing(reset_every) && (i % reset_every == 0 || i == num_games)
      reset!(baseline)
      reset!(contender)
    end
    if color_policy == ALTERNATE_COLORS
      baseline_white = !baseline_white
    end
  end
  return zsum / num_games
end
