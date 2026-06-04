# docker run -d \
#         --name oracle-free \
#         -p 1521:1521 -p 5500:5500 \
#         -e ORACLE_PWD=OraclePwd_2025 \
#         -v $HOME/oracle/full_data:/opt/oracle/oradata \
#         container-registry.oracle.com/database/free:latest

# Fixed by copilot:

docker rm -f oracle-free

docker volume create oracle_free_data

docker run -d `
  --name oracle-free `
  --network bridge `
  --hostname oracle-free `
  -p 1521:1521 -p 5500:5500 `
  -e ORACLE_PWD=OraclePwd_2025 `
  -e ORACLE_SID=FREE `
  -e ORACLE_PDB=FREEPDB1 `
  -v oracle_free_data:/opt/oracle/oradata `
  container-registry.oracle.com/database/free:latest