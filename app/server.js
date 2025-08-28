const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.type('text/plain').send('Hello from TickBoard side project on EKS via Harbor → GitHub Actions → Terraform!');
});

app.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
