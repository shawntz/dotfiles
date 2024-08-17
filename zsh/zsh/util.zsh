#!/bin/zsh

print_in_color() {
  printf "%b" \
    "$(tput setaf "$2" 2> /dev/null)" \
    "$1" \
    "$(tput sgr0 2> /dev/null)"
}

print_in_green() {
  print_in_color "$1" 2
}

print_in_purple() {
  print_in_color "$1" 5
}

print_in_red() {
  print_in_color "$1" 1
}

print_in_yellow() {
  print_in_color "$1" 11
}

print_in_orange() {
  print_in_color "$1" 3
}

print_in_cyan() {
  print_in_color "$1" 6
}

print_in_blue() {
  print_in_color "$1" 4
}

print_in_white() {
  print_in_color "$1" 7
}

print_in_black() {
  print_in_color "$1" 0
}

print_in_bright_black() {
  print_in_color "$1" 8
}

rel_path() {
  echo "$1" | sed "s|^$HOME/|~/|"
}

