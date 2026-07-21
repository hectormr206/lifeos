from axi import mesh_enroll, mesh_trust

def test_enroll_cli_can_provision_local_membership_certificate(tmp_path):
    mesh_trust.init_mesh("passphrase", base_dir=tmp_path)
    _private, public = mesh_trust.new_node_keypair(tmp_path, store=True)
    output = []
    status = mesh_enroll.main(
        ["--node-pubkey", public, "--save-local", "--base-dir", str(tmp_path)],
        prompt=lambda _message: "passphrase", out=output.append,
    )
    assert status == 0
    assert mesh_trust.load_membership_certificate(tmp_path) == output[0]
    assert mesh_trust.load_local_identity(tmp_path)[1] == output[0]

def test_save_local_rejects_certificate_for_another_node(tmp_path):
    mesh_trust.init_mesh("passphrase", base_dir=tmp_path)
    mesh_trust.new_node_keypair(tmp_path, store=True)
    _other_private, other_public = mesh_trust.new_node_keypair()
    status = mesh_enroll.main(
        ["--node-pubkey", other_public, "--save-local", "--base-dir", str(tmp_path)],
        prompt=lambda _message: "passphrase", out=lambda _token: None,
    )
    assert status == 1
    try:
        mesh_trust.load_membership_certificate(tmp_path)
    except mesh_trust.MeshNotInitialized as exc:
        assert "membership certificate" in str(exc)
    else:
        raise AssertionError("mismatched certificate was persisted")
