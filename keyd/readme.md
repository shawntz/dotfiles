# keyd installation

## build from source

```bash
git clone https://github.com/rvaiya/keyd
cd keyd
make && sudo make install
sudo systemctl enable keyd && sudo systemctl start keyd
```

## copy config

```bash
sudo cp default.conf /etc/keyd/default.conf
```

## reload config

```bash
sudo keyd reload
```

## dependencies

make sure `make` and `cmake` are installed
