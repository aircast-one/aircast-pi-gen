FROM python:3.12-slim-trixie
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
ADD https://github.com/shvartzj1/jetkvm-mcp.git#49c72cd4b5412325ebb3f87dc45ee708edb879f2 /opt/jetkvm-mcp
ENV PYTHONPATH=/opt/jetkvm-mcp PYTHONUNBUFFERED=1
COPY kvm_recv.py /app/kvm_recv.py
WORKDIR /out
ENTRYPOINT ["python", "/app/kvm_recv.py"]
