if type "xrandr"; then
  for m in $(xrandr --query | grep " connected" | cut -d" " -f1); do
    MONITOR=$m polybar --config=/home/shawn/.config/polybar/config.ini --reload toph &
  done
else
  polybar --reload toph &
fi
