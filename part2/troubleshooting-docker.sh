docker rm oracle-full

mkdir -p $HOME/oracle/full_data
docker rm -f oracle-full 2>/dev/null

docker run -d \
  --name oracle-full \
  -p 1521:1521 -p 5500:5500 \
  -e ORACLE_PWD=OraclePwd_2025 \
  -e ORACLE_SID=FREE \
  -e ORACLE_PDB=FREEPDB1 \
  -v $HOME/oracle/full_data:/opt/oracle/oradata \
  container-registry.oracle.com/database/free:latest
