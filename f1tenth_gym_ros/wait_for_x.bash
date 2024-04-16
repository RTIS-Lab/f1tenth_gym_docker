# block until an X server is running

while ! xset q &>/dev/null; do
  echo "Waiting for X server to start..."
  sleep 1
done