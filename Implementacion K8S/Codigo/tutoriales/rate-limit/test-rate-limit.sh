#!/bin/bash

# Script simple para testear Rate Limiting
# Uso: ./test-rate-limit.sh

API_URL="http://127.0.0.1:5000/api/drug"
TOTAL=120

echo "Test Rate Limiting - Enviando $TOTAL peticiones..."
echo ""

success=0
rate_limited=0

for i in $(seq 1 $TOTAL); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL")
    
    if [ "$code" = "200" ]; then
        success=$((success + 1))
        echo "[$i/$TOTAL] ✓"
    elif [ "$code" = "429" ]; then
        rate_limited=$((rate_limited + 1))
        echo "[$i/$TOTAL] ⚠ 429 Rate Limited"
    else
        echo "[$i/$TOTAL] ✗ Error $code"
    fi
    
    sleep 0.1
done

echo ""
echo "Resultados:"
echo "  Exitosas: $success"
echo "  Rate Limited (429): $rate_limited"
echo ""

if [ $rate_limited -gt 0 ]; then
    echo "✓ Rate limiting funciona"
else
    echo "⚠ Rate limiting no se activó"
fi

