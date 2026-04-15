




ecco alcuni comandi da implementare


```
pbm ping
# fa un ping al server, se è attivo risponde con pong 
```

```
pbm status
# chiama la api status /api/status e mostra lo stato del server
```

```
pbm clone [nome_packetto]
# esegue il clone del packetto, costruendo lo url $PACKBASE_URL/$nome_packetto
```

```
pbm info [nome_packetto]
# chiama la api /api/info/$nome_packetto e mostra le informazioni del packetto
```

```
pbm fetch [git_url]
# registra i tarall e il packetto sul server puntato da PACKBASE_URL, eseguendo una chiamata alla api /api/fetch con il git_url del packetto
```

```
pbm update
# esegue la api /api/update per aggiornare la lista dei taralli e dei pacchetti disponibili
```



