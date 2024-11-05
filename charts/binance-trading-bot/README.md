# Binance Trading Bot Helm chart

This is the official Helm chart for Binance Trading Bot.

This chart expects secrets to be created separately. Before installing the
chart, create a secret with the following structure:

First, create a namespace for the bot:

```bash
kubectl create namespace trading
```

Then, create a secret with the following structure:

```bash
kubectl create secret generic binance-trading-bot-secrets \
  --from-literal=binance-live-api-key='your-live-api-key' \
  --from-literal=binance-live-secret-key='your-live-secret-key' \
  --from-literal=binance-test-api-key='your-test-api-key' \
  --from-literal=binance-test-secret-key='your-test-secret-key' \
  --from-literal=redis-password='your-redis-password' \
  --namespace=trading  # Change 'default' to your target namespace if needed
```

The chart will look for these secrets during installation. Make sure to create
the secrets before installing the chart.

To install via Helm, run the following command.

```bash
helm upgrade --install trading -n trading --create-namespace \
  --repo https://helm.chrislee.kr/binance-trading-bot/ binance-trading-bot
```

Alternatively, add the Helm repository first and scan for updates.

```bash
helm repo add binance-trading-bot https://helm.chrislee.kr/binance-trading-bot/
helm repo update
```

Next, install the chart.

```bash
helm install trading trading/binance-trading-bot -n trading --create-namespace \
  --set binanceLiveApiKey="<Binance API key for live>" \
  --set binanceLiveSecretKey="<Binance API secret for live>"
```

The following table lists commonly used configuration parameters for the Binance
Trading Bot Helm chart and their default values. Please see the values file for
the complete set of definable values.

| Parameter                                     | Description                       | Default |
| --------------------------------------------- | --------------------------------- | ------- |
| binanceBot.config.binance.live.apiKey         | Binance API key for live          |         |
| binanceBot.config.binance.live.secretKey      | Binance API secret for live       |         |
| binanceBot.config.binance.live.existingSecret | Name of existing secret for live  |         |
| binanceBot.config.binance.test.apiKey         | Binance API key for test          |         |
| binanceBot.config.binance.test.secretKey      | Binance API secret for test       |         |
| binanceBot.config.binance.test.existingSecret | Name of existing secret for test  |         |
| binanceBot.config.redis.existingSecret        | Name of existing secret for Redis |         |
