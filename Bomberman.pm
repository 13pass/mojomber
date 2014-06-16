#!/usr/bin/env perl
package Bomberman;
use Modern::Perl;

my $PLAYERS = {};
my $BOMBS = {};
my $arena = [
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    [1, 0, 0, 0, 0, 0, 0, 0, 0, 1],
    [1, 0, 0, 1, 0, 1, 1, 1, 0, 1],
    [1, 0, 1, 0, 0, 0, 0, 1, 0, 1],
    [1, 0, 0, 0, 0, 1, 0, 1, 0, 1],
    [1, 0, 1, 1, 0, 0, 0, 0, 0, 1],
    [1, 0, 0, 1, 0, 1, 1, 1, 0, 1],
    [1, 1, 0, 1, 0, 0, 0, 1, 0, 1],
    [1, 0, 0, 1, 0, 1, 0, 0, 0, 1],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
];

sub new {
  my ($class) = @_;
  my $self = {};
  bless($self, $class);
  return $self;
}

sub connect_player {
  my $class = shift;
  my $control = shift;
  my $cid = _get_id($control);
  $PLAYERS->{$cid}->{tx} = $control->tx;

  $control->app->log->debug("Player connected");
  my $player = $PLAYERS->{$cid};

  $player->{nick}  = 'Bomber' . int(rand(10000));
  $player->{pos}   = _get_random_pos();
  $player->{frags} = 0;

  $control->app->log->debug('Send arena');
  _send_message($control, type => 'drawarena', arena => $arena);

  $control->app->log->debug('Send self info');
  _send_message($control, type => 'player', _get_player_info($cid));

  $control->app->log->debug('Send other players info');
  my $other_players = [grep { $_->{id} ne $cid } @{_get_players()}];
  _send_message($control, type => 'initplayers', players => $other_players);

  $control->app->log->debug('Send bombs');
  _send_message($control, type => 'initbombs', bombs => _get_bombs());

  $control->app->log->debug('Notify other players about a new player');
  _send_message_to_other(
    $control,
    type => 'new_player',
    _get_player_info($cid)
  );
  return $cid;
}
    
sub disconnect_player {
  my $class = shift;
  my $control = shift;
  my $cid = _get_id($control);
  _send_message_to_other($control, type => 'old_player', id => $cid);

  $control->app->log->debug("Player disconnected");
  delete $PLAYERS->{$cid};
}

sub handle_move {
  my $class = shift;
  my $control = shift;
  my $message = shift;

  my $id = _get_id($control);
  my $direction = $message->{direction};

  return unless $id && $direction;

  my $player = $PLAYERS->{$id};

  my $row = $player->{pos}->[0];
  my $col = $player->{pos}->[1];

  if ($direction eq 'up') {
      $row--;
  }
  elsif ($direction eq 'down') {
      $row++;
  }
  elsif ($direction eq 'left') {
      $col--;
  }
  elsif ($direction eq 'right') {
      $col++;
  }

  # Can't go through the wall
  return if $arena->[$row]->[$col];

  # Can't go through the bomb
  foreach my $id (keys %$BOMBS) {
    my ($r, $c) = @{$BOMBS->{$id}->{pos}};
    return if $row == $r && $col == $c;
  }

  $player->{pos}->[0] = $row;
  $player->{pos}->[1] = $col;
  _send_message_to_all(
    $control,
    type      => 'move',
    id        => $id,
    direction => $direction
  );
}



sub handle_bomb {
  my $class = shift;
  my $control = shift;
  my $message = shift;

  my $cid = _get_id($control);

  my $player = $PLAYERS->{$cid};

  if (!$player->{bomb}) {
    $control->app->log->debug('Player set up a bomb');

    $player->{bomb} = 1;
    my $bomb = $BOMBS->{$cid} = {pos => [@{$player->{pos}}]};

    _send_message_to_other(
      $control,
      type => 'bomb',
      id   => $cid,
      pos  => $bomb->{pos}
    );

    Mojo::IOLoop->timer(
      2,
      sub {
        my $player = $PLAYERS->{$cid};
        my $bomb = delete $BOMBS->{$cid};

        # If we are still connected
        if ($player) {
          $player->{bomb} = 0;
        }

        # Get bomb position
        my ($row, $col) = @{$bomb->{pos}};

        my @dead;
        my $me;
        _walk_arena(
          $arena, $row, $col, 3,
          sub {
            my ($row, $col) = @_;

            foreach my $pid (keys %$PLAYERS) {
              my ($p_row, $p_col) =@{$PLAYERS->{$pid}->{pos}};

              if ($p_row eq $row && $p_col eq $col) {

                # If we are connected and dead
                if ($PLAYERS->{$cid} && $cid eq $pid) {
                    $me = 1;
                }

                push @dead, $pid;
              }
            }
          }
        );

        _send_message_to_all($control, id => $cid, type => 'explode');

        # If there are any dead players
        if (@dead) {

          # If we killed ourself
          if ($me) {
              $player->{frags} -= 1;
          }

          # If not and connected
          elsif ($player) {
              $player->{frags} += @dead;
          }

          # Resurection
          Mojo::IOLoop->timer(
              5,
              sub {
                  my @players = map {
                      {id => $_, pos => _get_random_pos()}
                  } @dead;

                  foreach my $player (@players) {
                      $PLAYERS->{$player->{id}}->{pos} =
                        $player->{pos};
                  }

                  _send_message_to_all(
                      $control,
                      type    => 'alive',
                      players => [@players]
                  );
              }
          );

          _send_message_to_all(
              $control,
              type    => 'die',
              players => [@dead]
          );

          # Update frags if we are connected
          _send_message_to_all(
              $control,
              type  => 'frags',
              id    => $cid,
              frags => $player->{frags}
          ) if $player;
        }
      }
    );
  }
}

sub _get_id {
  my $self = shift;
  #$c->app->log->debug(p($c));
  my $tx = $self->tx;
  return "$tx";
}

sub _walk_arena {
  my ($arena, $row, $col, $radius, $cb) = @_;

  my $mrow = @$arena;
  my $mcol = @{$arena->[0]};

  $cb->($row, $col);

  for (my $i = 1; $i < $radius; $i++) {
    if ($row + $i < $mrow) {
      last if $arena->[$row + $i]->[$col];

      $cb->($row + $i, $col);
    }
  }

  for (my $i = 1; $i < $radius; $i++) {
      if ($row - $i > 0) {
          last if $arena->[$row - $i]->[$col];

          $cb->($row - $i, $col);
      }
  }

  for (my $i = 1; $i < $radius; $i++) {
      if ($col + $i < $mcol) {
          last if $arena->[$row]->[$col + $i];

          $cb->($row, $col + $i);
      }
  }

  for (my $i = 1; $i < $radius; $i++) {
      if ($col - $i > 0) {
          last if $arena->[$row]->[$col - $i];

          $cb->($row, $col - $i);
      }
  }
}

sub _get_random_pos {
  my @pos;
  for (my $i = 0; $i < @$arena; $i++) {
    for (my $j = 0; $j < @{$arena->[0]}; $j++) {
      push @pos, [$i => $j] unless $arena->[$i]->[$j];
    }
  }

  my $rand = int(rand(@pos));

  return $pos[$rand];
}

sub _get_player_info {
  my $cid = shift;

  my $player = $PLAYERS->{$cid};
  return unless $player;

  return (
    id    => $cid,
    pos   => $player->{pos},
    frags => $player->{frags},
    nick  => $player->{nick}
  );
}

sub _get_players {
  return [] unless keys %$PLAYERS;

  return [map { { _get_player_info($_) } } keys %$PLAYERS];
}

sub _get_bombs {
  return [] unless keys %$BOMBS;

  return [map { {id => $_, pos => $BOMBS->{$_}->{pos}} } keys %$BOMBS];
}

sub _send_message {
  my $self = shift;

  $self->send({json => {@_}});
}

sub _send_message_to_other {
  my $self = shift;
  my %message = @_;

  my $id = _get_id($self);

  foreach my $cid (keys %$PLAYERS) {
    next if $cid eq $id;

    my $player = $PLAYERS->{$cid};

    # If player is connected
    if ($player && $player->{tx}) {
      $PLAYERS->{$cid}->{tx}->send({json => { %message} });
    }

    # Cleanup disconnected player
    else {
      delete $PLAYERS->{$cid};
    }
  }
}

sub _send_message_to_all {
  _send_message_to_other(@_);
  _send_message(@_);
}

1;
